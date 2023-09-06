module staking::staking {

    use aptos_framework::event::EventHandle;
    use aptos_std::table::Table;
    use aptos_std::table;
    use aptos_framework::block;
    use aptos_framework::timestamp;
    use staking::i128::{Self, I128};
    use std::signer;
    use aptos_framework::event;
    use token::token::{Token};
    use aptos_framework::coin;
    use aptos_framework::account::new_event_handle;
    use aptos_framework::coin::Coin;

    struct Point has drop, store, copy {
        bias: I128,
        // b from y = ax + b
        slope: I128,
        // a from y = ax + b
        ts: u64,
        // timestamp seconds
        blk: u64,
        // block number/height
    }

    struct LockedBalance has store, copy, drop {
        amount: u64,
        end: u64 // lock end timestamp in seconds, rounded to week precision
    }

    const ENOT_ADMIN: u64 = 10;
    const EACCESS_DENIED: u64 = 20;
    const EBAD_AMOUNT: u64 = 30;
    const ELOCK_NOT_FOUND: u64 = 40;
    const ELOCK_EXPIRED: u64 = 50;
    const ELOCK_ALREADY_EXISTS: u64 = 60;
    const ETIME_IN_PAST: u64 = 70;
    const EMAX_TIME_LIMIT: u64 = 80;
    const ELOCK_NOT_EXPIRED: u64 = 90;

    const DEPOSIT_FOR_TYPE: u64 = 0;
    const CREATE_LOCK_TYPE: u64 = 1;
    const INCREASE_LOCK_AMOUNT: u64 = 2;
    const INCREASE_UNLOCK_TIME: u64 = 3;

    struct StakingEvents has key {
        deposit_events: EventHandle<DepositEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
        supply_events: EventHandle<SupplyEvent>,
    }

    struct DepositEvent has drop, store {
        provider: address,
        value: u64,
        locktime: u64,
        type: u64,
        ts: u64
    }

    struct WithdrawEvent has drop, store {
        provider: address,
        value: u64,
        ts: u64
    }

    struct SupplyEvent has drop, store {
        prevSupply: u64,
        supply: u64
    }

    const WEEK: u64 = 7 * 86400;
    // all future times are rounded by week
    const MAXTIME: u64 = 4 * 365 * 86400;
    // 4 years
    const MULTIPLIER: u64 = 10 ^ 18;

    struct UserHistoryInfo has key, store {
        user_point_history: Table<u64, Point>,
        user_point_epoch: u64
    }

    struct State has key {
        locked: Table<address, LockedBalance>,
        epoch: u64,
        point_history: Table<u64, Point>,
        slope_changes: Table<u64, I128>,
        // time -> signed slope change,
        supply: Coin<Token>
    }

    fun assert_admin(admin: &signer) {
        let addr = signer::address_of(admin);
        assert!(@staking == addr, ENOT_ADMIN);
    }

    #[test_only]
    public entry fun init_module_for_test(resource_account: &signer) {
        init_module(resource_account);
    }

    entry fun init_module(resource_account: &signer) {
        let initial_point = Point {
            bias: i128::zero(),
            slope: i128::zero(),
            ts: timestamp::now_seconds(),
            blk: block::get_current_block_height()
        };
        let point_history = table::new();
        table::add(&mut point_history, 0, initial_point);

        coin::register<Token>(resource_account);

        move_to(
            resource_account,
            State {
                locked: table::new(),
                epoch: 0,
                point_history,
                slope_changes: table::new(),
                supply: coin::zero()
            });

        move_to(
            resource_account,
            StakingEvents {
                deposit_events: new_event_handle<DepositEvent>(resource_account),
                withdraw_events: new_event_handle<WithdrawEvent>(resource_account),
                supply_events: new_event_handle<SupplyEvent>(resource_account),
            }
        );
    }

    // @notice Record global data to checkpoint
    public entry fun checkpoint(signer: &signer) acquires State, UserHistoryInfo {
        checkpoint_internal(
            signer,
            borrow_global_mut<State>(signer::address_of(signer)),
            &LockedBalance { amount: 0, end: 0 },
            &LockedBalance { amount: 0, end: 0 }
        );
    }

    //     """
    //     @notice Record global and per-user data to checkpoint
    //     @param addr User's wallet address. No user checkpoint if 0x0
    //     @param old_locked Pevious locked amount / end lock time for the user
    //     @param new_locked New locked amount / end lock time for the user
    //     """
    fun checkpoint_internal(
        signer: &signer,
        state: &mut State,
        old_locked: &LockedBalance,
        new_locked: &LockedBalance
    ) acquires UserHistoryInfo {
        let u_old: Point = Point { bias: i128::zero(), slope: i128::zero(), ts: 0, blk: 0 };
        let u_new: Point = Point { bias: i128::zero(), slope: i128::zero(), ts: 0, blk: 0 };
        let old_dslope = i128::zero();
        let new_dslope = i128::zero();
        let _epoch = state.epoch;

        let now_seconds = timestamp::now_seconds();
        let block_height = block::get_current_block_height();
        let addr = signer::address_of(signer);

        if (addr != @staking) {
            // # Calculate slopes and biases
            // # Kept at zero when they have to
            if (old_locked.end > now_seconds && old_locked.amount > 0) {
                u_old.slope = i128::from(((old_locked.amount / MAXTIME) as u128));
                let dt = old_locked.end - now_seconds;
                u_old.bias = i128::mul(&u_old.slope, &i128::from((dt as u128)));
            };
            if (new_locked.end > now_seconds && new_locked.amount > 0) {
                u_new.slope = i128::from((new_locked.amount / MAXTIME as u128));
                let dt = new_locked.end - now_seconds;
                u_new.bias = i128::mul(&u_new.slope, &i128::from((dt as u128)));
            };
            // # Read values of scheduled changes in the slope
            // # old_locked.end can be in the past and in the future
            // # new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = *table::borrow_with_default(&mut state.slope_changes, old_locked.end, &i128::zero());
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope
                } else {
                    new_dslope = *table::borrow_with_default(&mut state.slope_changes, new_locked.end, &i128::zero());
                };
            };
        };

        let last_point;
        if (_epoch > 0) {
            let ref = table::borrow_mut(&mut state.point_history, _epoch);
            last_point = Point { bias: ref.bias, slope: ref.slope, ts: ref.ts, blk: ref.blk };
        } else {
            last_point = Point { bias: i128::zero(), slope: i128::zero(), ts: now_seconds, blk: block_height };
        };
        let last_checkpoint = last_point.ts;
        // # initial_last_point is used for extrapolation to calculate block number
        // # (approximately, for *At methods) and save them
        // # as we cannot figure that out exactly from inside the contract
        let initial_last_point = Point {
            bias: last_point.bias,
            slope: last_point.slope,
            ts: last_point.ts,
            blk: last_point.blk
        };
        let block_slope = 0;  // # dblock/dt
        if (now_seconds > last_point.ts) {
            block_slope = MULTIPLIER * (block_height - last_point.blk) / (now_seconds - last_point.ts);
        };

        // # If last point is already recorded in this block, slope=0
        // # But that's ok b/c we know the block in such case

        // # Go over weeks to fill history and calculate what the current point is
        let t_i = (last_checkpoint / WEEK) * WEEK;
        let i = 0;
        while (i < 255) {
            // # Hopefully it won't happen that this won't get used in 5 years!
            // # If it does, users will be able to withdraw but vote weight will be broken
            t_i = t_i + WEEK;
            let d_slope = i128::zero();
            if (t_i > now_seconds) {
                t_i = now_seconds;
            } else {
                d_slope = *table::borrow_with_default(&mut state.slope_changes, t_i, &i128::zero());
            };
            let t_i_sub_last_cp = i128::sub(&i128::from((t_i as u128)), &i128::from((last_checkpoint as u128)));
            last_point.bias = i128::sub(&last_point.bias, &i128::mul(&last_point.slope, &t_i_sub_last_cp));
            last_point.slope = i128::add(&last_point.slope, &d_slope);
            if (i128::is_neg(&last_point.bias)) {
                // # This can happen
                last_point.bias = i128::zero();
            };
            if (i128::is_neg(&last_point.slope)) {
                // # This cannot happen - just in case
                last_point.slope = i128::zero();
            };
            last_checkpoint = t_i;
            last_point.ts = t_i;
            last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) / MULTIPLIER;
            _epoch = _epoch + 1;

            if (t_i == now_seconds) {
                last_point.blk = block_height;
                break
            } else {
                table::upsert(&mut state.point_history, _epoch, last_point);
            };
            i = i + 1;
        };

        state.epoch = _epoch;
        // # Now point_history is filled until t=now

        if (addr != @staking) {
            // # If last point was in this block, the slope change has been applied already
            // # But in such case we have 0 slope(s)
            last_point.slope = i128::add(&last_point.slope, &i128::sub(&u_new.slope, &u_old.slope));
            last_point.bias = i128::add(&last_point.bias, &i128::sub(&u_new.bias, &u_old.bias));
            if (i128::is_neg(&last_point.slope)) {
                last_point.slope = i128::zero();
            };
            if (i128::is_neg(&last_point.bias)) {
                last_point.bias = i128::zero();
            };
        };
        // # Record the changed point into history

        table::upsert(&mut state.point_history, _epoch, last_point);

        if (addr != @staking) {
            // # Schedule the slope changes (slope is going down)
            // # We subtract new_user_slope from [new_locked.end]
            // # and add old_user_slope to [old_locked.end]
            if (old_locked.end > now_seconds) {
                // # old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope = i128::add(&old_dslope, &u_old.slope);
                if (new_locked.end == old_locked.end)
                    old_dslope = i128::sub(&old_dslope, &u_new.slope);  //# It was a new deposit, not extension

                table::upsert(&mut state.slope_changes, old_locked.end, old_dslope);
            };

            if (new_locked.end > now_seconds) {
                if (new_locked.end > old_locked.end) {
                    new_dslope = i128::sub(&new_dslope, &u_new.slope);  // # old slope disappeared at this point
                    table::upsert(&mut state.slope_changes, new_locked.end, new_dslope);
                };
            }; // # else: we recorded it already in old_dslope

            // # Now handle user history
            if (!exists<UserHistoryInfo>(addr)) {
                move_to(signer, UserHistoryInfo {
                    user_point_history: table::new(),
                    user_point_epoch: 0
                });
            };
            let user_history_info = borrow_global_mut<UserHistoryInfo>(addr);
            user_history_info.user_point_epoch = user_history_info.user_point_epoch + 1;

            u_new.ts = now_seconds;
            u_new.blk = block_height;
            let user_point_history = &mut user_history_info.user_point_history;

            table::upsert(user_point_history, user_history_info.user_point_epoch, u_new);
        };
    }

    // """
    // @notice Deposit `_value` tokens for `_addr` and add to the lock
    // @dev Anyone (even a smart contract) can deposit for someone else, but
    // cannot extend their locktime and deposit for a brand new user
    // @param _addr User's wallet address
    // @param _value Amount to add to user's lock
    // """
    entry fun deposit_for(signer: &signer, value: u64) acquires State, StakingEvents, UserHistoryInfo {
        let addr = signer::address_of(signer);
        let state = borrow_global_mut<State>(@staking);
        let locked = table::borrow_mut(&mut state.locked, addr);

        let locked_balance = LockedBalance {
            amount: locked.amount,
            end: locked.end
        };
        deposit_internal(signer, value, 0, locked_balance, DEPOSIT_FOR_TYPE);
    }

    //    """
    //    @notice Deposit `_value` additional tokens for `msg.sender`
    //    without modifying the unlock time
    //    @param _value Amount of tokens to deposit and add to the lock
    //    """
    public entry fun increase_amount(signer: &signer, value: u64) acquires State, StakingEvents, UserHistoryInfo {
        let addr = signer::address_of(signer);
        let state = borrow_global_mut<State>(@staking);
        let locked = table::borrow_mut_with_default(&mut state.locked, addr, LockedBalance { amount: 0, end: 0 });

        let locked_balance = LockedBalance {
            amount: locked.amount,
            end: locked.end
        };

        assert!(value > 0, EBAD_AMOUNT); //  # dev: need non-zero value
        assert!(locked.amount > 0, ELOCK_NOT_FOUND); // "No existing lock found"
        assert!(locked.end > timestamp::now_seconds(), ELOCK_EXPIRED); // "Cannot add to expired lock. Withdraw"

        deposit_internal(signer, value, 0, locked_balance, INCREASE_LOCK_AMOUNT)
    }

    // @notice Deposit and lock tokens for a user
    // @param _addr User's wallet address
    // @param _value Amount to deposit
    // @param unlock_time New time when to unlock the tokens, or 0 if unchanged
    // @param locked_balance Previous locked amount / timestamp
    fun deposit_internal(
        signer: &signer,
        value: u64, // pass zero to keep unchanged
        unlock_time: u64, // pass zero to keep unchanged
        locked_balance: LockedBalance, // existing lock or default lock with zeros
        type: u64
    ) acquires State, StakingEvents, UserHistoryInfo {
        let _addr = signer::address_of(signer);
        let state = borrow_global_mut<State>(@staking);

        let supply_before = coin::value(&state.supply);

        let old_locked = LockedBalance {
            amount: locked_balance.amount,
            end: locked_balance.end
        };
        // # Adding to existing lock, or if a lock is expired - creating a new one
        locked_balance.amount = locked_balance.amount + value;
        if (unlock_time != 0) {
            locked_balance.end = unlock_time;
        };
        table::upsert(&mut state.locked, signer::address_of(signer), locked_balance);

        // # Possibilities:
        // # Both old_locked.end could be current or expired (>/< block.timestamp)
        // # value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // # _locked.end > block.timestamp (always)
        checkpoint_internal(signer, state, &old_locked, &locked_balance);

        if (value != 0) {
            let deposit_coin = coin::withdraw<Token>(signer, value);
            coin::merge(&mut state.supply, deposit_coin);
        };
        event::emit_event<DepositEvent>(
            &mut (borrow_global_mut<StakingEvents>(@staking).deposit_events),
            DepositEvent {
                provider: signer::address_of(signer),
                value,
                locktime: locked_balance.end,
                type,
                ts: timestamp::now_seconds()
            }
        );
        event::emit_event<SupplyEvent>(
            &mut (borrow_global_mut<StakingEvents>(@staking).supply_events),
            SupplyEvent {
                prevSupply: supply_before,
                supply: supply_before + value
            }
        );
    }

    // """
    // @notice Binary search to estimate timestamp for block number
    // @param _block Block to find
    // @param max_epoch Don't go beyond this epoch
    // @return Approximate timestamp for block
    // """
    fun find_block_epoch(_block: u64, max_epoch: u64, state: &State): u64 {
        let _min = 0;
        let _max = max_epoch;

        let i = 0;
        while (i < 128) {
            if(_min >= _max) {
                break
            };

            let _mid = (_min + _max + 1) / 2;

            let blk = table::borrow(&state.point_history, _mid).blk;

            if (blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            };
            i = i + 1;
        };
        _min
    }

    // """
    // @notice Measure voting power of `addr` at block height `_block`
    // @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    // @param addr User's wallet address
    // @param _block Block to calculate the voting power at
    // @return Voting power
    // """
    #[view]
    public fun balance_of_at(addr: address, _block: u64) : u128 acquires State, UserHistoryInfo {
        let current_block =  block::get_current_block_height();
        assert!(_block <= current_block, 100);

        let balance: u128 = 0;
        let current_ts =  timestamp::now_seconds();
        if (exists<UserHistoryInfo>(addr)) {
            let user_history_info = borrow_global<UserHistoryInfo>(addr);
            let epoch = user_history_info.user_point_epoch;
            let _min: u64 = 0;
            let _max: u64 = epoch;

            let i = 0;
            while (i < 128) {
                if  (_min >= _max) {
                    break
                };
                let _mid = (_min + _max + 1) / 2;
                let mid_point = table::borrow(&user_history_info.user_point_history, _mid);
                if (mid_point.blk <= _block) {
                    _min = _mid;
                } else {
                    _max = _mid - 1;
                };
                i = i + 1;
            };
            let borrowed_upoint = table::borrow(&user_history_info.user_point_history, _min);
            let upoint = Point {
                bias: borrowed_upoint.bias,
                slope: borrowed_upoint.slope,
                ts: borrowed_upoint.ts,
                blk: borrowed_upoint.blk
            };
            let state = borrow_global<State>(@staking);
            let max_epoch = state.epoch;
            let _epoch = find_block_epoch(_block, max_epoch, state);
            let point_0 = table::borrow(&state.point_history, _epoch);

            let d_block;
            let d_t;

            if (_epoch < max_epoch) {
                let point_1 = table::borrow(&state.point_history,_epoch + 1);
                d_block = point_1.blk - point_0.blk;
                d_t = point_1.ts - point_0.ts;
            } else {
                d_block = current_block - point_0.blk;
                d_t = current_ts - point_0.ts;
            };
            let block_time = point_0.ts;

            if (d_block != 0) {
                block_time = block_time + d_t * (_block - point_0.blk) / d_block;
            };
            upoint.bias = i128::sub(&upoint.bias, &i128::mul(&upoint.slope, &i128::from(((block_time - upoint.ts) as u128))));
            if (!i128::is_neg(&upoint.bias)) {
                balance = i128::as_u128(&upoint.bias);
            };
        };
        balance
    }

    // """
    // @notice Get the current voting power for `msg.sender`
    // @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    // @param addr User wallet address
    // @param _t Epoch time to return voting power at
    // @return User voting power
    // """
    #[view]
    public fun balance_of(addr: address): u128 acquires UserHistoryInfo {
        let balance;
        if (exists<UserHistoryInfo>(addr)) {
            let user_history_info = borrow_global<UserHistoryInfo>(addr);
            let epoch = user_history_info.user_point_epoch;
            if (epoch == 0) {
                balance = 0;
            } else {
                let now_ts = timestamp::now_seconds();
                let last_point = table::borrow(&user_history_info.user_point_history, epoch);
                let dt = i128::from(((now_ts - last_point.ts) as u128));
                let last_bias = i128::sub(&last_point.bias,  &i128::mul(&last_point.slope, &dt));
                if (i128::is_neg(&last_bias)) {
                    balance = 0;
                } else {
                    balance = i128::as_u128(&last_bias);
                };
            };
        } else {
            balance = 0;
        };
        balance
    }

    #[view]
    public fun lock_amount(addr: address): u64 acquires State {
        let state = borrow_global<State>(@staking);
        let locked = table::borrow_with_default(
            &state.locked,
            addr,
            &LockedBalance { amount: 0, end: 0 }
        );
        locked.amount
    }

    #[view]
    public fun lock_end(addr: address): u64 acquires State {
        let state = borrow_global<State>(@staking);
        let locked = table::borrow_with_default(
            &state.locked,
            addr,
            &LockedBalance { amount: 0, end: 0 }
        );
        locked.end
    }

    #[view]
    public fun estimated_ve_amount(amount: u64, unlock_time: u64): u128 {
        let slope = i128::from(((amount as u128) / (MAXTIME as u128)));

        let unlock_time_week_rounded = (unlock_time / WEEK) * WEEK;
        let dt = unlock_time_week_rounded - timestamp::now_seconds();

        let bias = i128::mul(&slope, &i128::from((dt as u128)));
        let bias_u128 = i128::as_u128(&bias);
        bias_u128
    }

    // """
    //     @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
    //     @param _value Amount to deposit
    //     @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
    //     """
    public entry fun create_lock(
        signer: &signer,
        value: u64,
        unlock_time: u64
    ) acquires State, StakingEvents, UserHistoryInfo {
        let unlock_time_week_rounded = (unlock_time / WEEK) * WEEK;

        let state = borrow_global<State>(@staking);
        let locked = table::borrow_with_default(
            &state.locked,
            signer::address_of(signer),
            &LockedBalance { amount: 0, end: 0 }
        );
        let now_seconds = timestamp::now_seconds();
        let max_lock_time = now_seconds + MAXTIME;
        assert!(value > 0, EBAD_AMOUNT);  // # dev: need non-zero value
        assert!(locked.amount == 0, ELOCK_ALREADY_EXISTS); // "Withdraw old tokens first"
        assert!(unlock_time_week_rounded > now_seconds, ETIME_IN_PAST); // "Can only lock until time in the future"
        assert!(unlock_time_week_rounded <= max_lock_time, EMAX_TIME_LIMIT); // "Voting lock can be 4 years max"

        let locked_balance = LockedBalance {
            amount: locked.amount,
            end: locked.end
        };
        deposit_internal(signer, value, unlock_time_week_rounded, locked_balance, CREATE_LOCK_TYPE)
    }

    // """
    // @notice Withdraw all tokens for `msg.sender`
    // @dev Only possible if the lock has expired
    // """
    public entry fun withdraw(signer: &signer) acquires State, StakingEvents, UserHistoryInfo {
        let state = borrow_global_mut<State>(@staking);
        let locked = table::borrow_with_default(
            &state.locked,
            signer::address_of(signer),
            &LockedBalance { amount: 0, end: 0 }
        );
        let amount = locked.amount;

        assert!(locked.end > 0, 123);
        assert!(timestamp::now_seconds() >= locked.end, ELOCK_NOT_EXPIRED); // "The lock didn't expire"
        assert!(amount > 0, EBAD_AMOUNT); // Empty lock

        let old_locked = LockedBalance { amount: locked.amount, end: locked.end };
        let zero_locked = LockedBalance { amount: 0, end: 0 };

        table::upsert(
            &mut state.locked,
            signer::address_of(signer),
            zero_locked
        );

        let supply_before = coin::value(&state.supply);

        // # old_locked can have either expired <= timestamp or zero end
        // # _locked has only 0 end
        // # Both can have > = 0 amount
        checkpoint_internal(signer, state, &old_locked, &zero_locked);

        if (amount != 0) {
            let coin_to_withdraw = coin::extract<Token>(&mut state.supply, amount);
            coin::deposit<Token>(signer::address_of(signer), coin_to_withdraw);
        };

        event::emit_event<WithdrawEvent>(
            &mut (borrow_global_mut<StakingEvents>(@staking).withdraw_events),
            WithdrawEvent {
                provider: signer::address_of(signer),
                value: amount,
                ts: timestamp::now_seconds()
            }
        );

        event::emit_event<SupplyEvent>(
            &mut (borrow_global_mut<StakingEvents>(@staking).supply_events),
            SupplyEvent {
                prevSupply: supply_before,
                supply: supply_before - amount
            }
        );
    }


}
