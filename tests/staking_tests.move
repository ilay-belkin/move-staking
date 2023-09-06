#[test_only]
module staking::staking_tests {

    use staking::staking::{Self, };
    use token::token::{Self, Token};
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    // use aptos_framework::aptos_account;
    use aptos_framework::account;
    use aptos_framework::block;
    use std::signer;
    use aptos_std::debug;

    const WEEK: u64 = 7 * 86400;
    const MAXTIME: u64 = 4 * 365 * 86400;

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        test_user2 = @test_user2,
        aptos_framework = @aptos_framework
    )]
    public fun test_create_lock_max_time(
        token: signer,
        staking: signer,
        test_user: signer,
        test_user2: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);

        let token_amount = 50000000000;

        let estimated_ve = staking::estimated_ve_amount(token_amount, timestamp::now_seconds() + MAXTIME);

        debug::print(&estimated_ve);

        staking::create_lock(&test_user, token_amount, timestamp::now_seconds() + MAXTIME);

        assert!(staking::lock_amount(@test_user) == token_amount, 100);

        let lock_end = staking::lock_end(@test_user);

        let token_balance_after = coin::balance<Token>(@test_user);
        assert!(token_balance_after == 10000000000000 - token_amount, 200);

        let estimated_ve = staking::estimated_ve_amount(token_amount, timestamp::now_seconds() + MAXTIME);
        assert!(estimated_ve == 49934981448, 300);

        let ve_balance = staking::balance_of(signer::address_of(&test_user));
        debug::print(&ve_balance);

        assert!(ve_balance == 49934981448, 400);

        let zero_balance = staking::balance_of(signer::address_of(&test_user2));
        assert!(zero_balance == 0, 500);

        // check dynamic for one day
        let i = 0;
        let prev_ve = 0;
        while (i < 60 * 60 * 24) {
            timestamp::fast_forward_seconds(1);
            ve_balance = staking::balance_of(signer::address_of(&test_user));
            if (prev_ve != 0) {
                let balance_delta = prev_ve - ve_balance;
                assert!(balance_delta == 396, 600); // 396 ~= ve_estimated / MAXTIME
                debug::print(&balance_delta);
            };
            debug::print(&ve_balance);

            prev_ve = ve_balance;
            i = i + 1;
        };

        staking::increase_amount(&test_user, 5000000000);

        assert!(staking::lock_amount(@test_user) == 55000000000, 600);
        assert!(staking::lock_end(@test_user) == lock_end, 700);
    }

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        aptos_framework = @aptos_framework
    )]
    public fun test_create_lock_min_time(
        token: signer,
        staking: signer,
        test_user: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);
        let token_amount = 50000000000;

        let lock_period = WEEK * 4;
        let estimated_ve = staking::estimated_ve_amount(token_amount, timestamp::now_seconds() + lock_period);

        debug::print(&estimated_ve);

        staking::create_lock(&test_user, token_amount, timestamp::now_seconds() + lock_period);

        assert!(staking::lock_amount(@test_user) == token_amount, 100);
        let lock_end = staking::lock_end(@test_user);
        assert!(lock_end <= timestamp::now_seconds() + lock_period, 101);

        let token_balance_after = coin::balance<Token>(@test_user);
        assert!(token_balance_after == 10000000000000 - token_amount, 200);

        let estimated_ve = staking::estimated_ve_amount(token_amount, timestamp::now_seconds() + lock_period);
        assert!(estimated_ve == 837317448, 300);

        let ve_balance = staking::balance_of(signer::address_of(&test_user));
        debug::print(&ve_balance);

        assert!(ve_balance == 837317448, 400);

        // check dynamic for one day
        let i = 0;
        let prev_ve = 0;
        while (i < 60 * 60 * 24) {
            timestamp::fast_forward_seconds(1);
            ve_balance = staking::balance_of(signer::address_of(&test_user));
            if (prev_ve != 0) {
                let balance_delta = prev_ve - ve_balance;
                assert!(balance_delta == 396, 600); // 396 ~= ve_estimated / MAXTIME
                debug::print(&balance_delta);
            };
            debug::print(&ve_balance);

            prev_ve = ve_balance;
            i = i + 1;
        };
    }

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        aptos_framework = @aptos_framework
    )]
    public fun test_create_lock_and_withdraw(
        token: signer,
        staking: signer,
        test_user: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);

        let duration = WEEK * 4;
        staking::create_lock(&test_user, 10000000000, timestamp::now_seconds() + duration);
        staking::increase_amount(&test_user, 5000000000);


        assert!(coin::balance<Token>(@test_user) == (10000000000000 - 10000000000 - 5000000000), 100);

        let lock_end = staking::lock_end(@test_user);
        timestamp::fast_forward_seconds(lock_end - timestamp::now_seconds() + 1);

        staking::withdraw(&test_user);
        assert!(coin::balance<Token>(@test_user) == 10000000000000, 200);
    }

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        aptos_framework = @aptos_framework
    )]
    #[expected_failure(abort_code = 90, location = staking)]
    public fun test_create_lock_and_withdraw_too_early(
        token: signer,
        staking: signer,
        test_user: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);

        let duration = WEEK * 4;
        staking::create_lock(&test_user, 10000000000, timestamp::now_seconds() + duration);
        staking::increase_amount(&test_user, 5000000000);

        let lock_end = staking::lock_end(@test_user);
        timestamp::fast_forward_seconds((lock_end - timestamp::now_seconds()) - 1);
        staking::withdraw(&test_user);

        assert!(coin::balance<Token>(@test_user) == 10000000000000, 200);
    }

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        aptos_framework = @aptos_framework
    )]
    #[expected_failure(abort_code = 40, location = staking)]
    public fun test_increase_empty_lock(
        token: signer,
        staking: signer,
        test_user: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);
        staking::increase_amount(&test_user, 5000000000);
    }

    fun setup_for_test(token: &signer,
                       staking: &signer,
                       test_user: &signer,
                       aptos_framework: &signer) {
        account::create_account_for_test(@token);
        account::create_account_for_test(@staking);
        account::create_account_for_test(@test_user);
        account::create_account_for_test(@aptos_framework);

        block::initialize_for_test(aptos_framework, 2 * 60 * 60 * 1000000);

        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1688906362);

        token::initialize(token, 10000000000000);

        coin::register<Token>(test_user);

        coin::transfer<Token>(token, @test_user, 10000000000000);
        staking::init_module_for_test(staking);

        let token_balance_before = coin::balance<Token>(@test_user);
        assert!(token_balance_before == 10000000000000, 100);
    }

    #[test(
        token = @token,
        staking = @staking,
        test_user = @test_user,
        test_user2 = @test_user2,
        aptos_framework = @aptos_framework
    )]
    public fun test_balance_of_at(
        token: signer,
        staking: signer,
        test_user: signer,
        aptos_framework: signer
    ) {
        setup_for_test(&token, &staking, &test_user, &aptos_framework);

        let token_amount = 50000000000;

        let estimated_ve = staking::estimated_ve_amount(token_amount, timestamp::now_seconds() + MAXTIME);

        debug::print(&estimated_ve);

        staking::create_lock(&test_user, token_amount, timestamp::now_seconds() + MAXTIME);

        staking::checkpoint(&staking);

        assert!(staking::lock_amount(@test_user) == token_amount, 100);

        let ve_balance = staking::balance_of_at(signer::address_of(&test_user), block::get_current_block_height());
        debug::print(&ve_balance);

        assert!(ve_balance == 49934981448, 400);
    }
}
