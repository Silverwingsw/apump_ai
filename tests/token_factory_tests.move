#[test_only]
module apump_ai::token_factory_tests {
    use std::string;

    #[test_only]
    use aptos_std::signer;

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    use aptos_framework::aptos_coin::AptosCoin;

    #[test_only]
    use aptos_framework::coin;

    #[test_only]
    use aptos_framework::fungible_asset;

    #[test_only]
    use aptos_framework::fungible_asset::Metadata;

    #[test_only]
    use aptos_framework::object;

    #[test_only]
    use aptos_framework::primary_fungible_store;

    #[test_only]
    use apump_ai::token_factory::{CompetitionData, FinancialData};

    #[test_only]
    use apump_ai::token_factory;

    fun init_for_testing(admin: &signer) {
        token_factory::init_module(admin);
    }

    #[test(admin = @0x1)]
    fun test_create_token_with_apt_precision(admin: &signer) {
        init_for_testing(admin);
        let name = string::utf8(b"TestToken");
        let symbol = string::utf8(b"TT");
        let max_supply = 10000000000000000;
        let decimals = 8;
        let icon_uri = string::utf8(b"[invalid url, do not cite]");
        let project_uri = string::utf8(b"[invalid url, do not cite]");

        let token_addr = token_factory::create_token(admin, name, symbol, max_supply, decimals, icon_uri, project_uri);
        let metadata_obj = object::address_to_object<Metadata>(token_addr);
        assert!(fungible_asset::decimals(metadata_obj) == 8, 0);
        assert!(fungible_asset::name(metadata_obj) == name, 1);
        assert!(fungible_asset::symbol(metadata_obj) == symbol, 2);
    }

    #[test(admin = @0x1)]
    fun test_buy_token(admin: &signer) acquires token_factory::FinancialData, token_factory::CompetitionData, token_factory::FAController {
        init_for_testing(admin);
        let buyer = account::create_account_for_test(@0x123);
        let buyer_addr = signer::address_of(&buyer);

        let name = string::utf8(b"TestToken");
        let symbol = string::utf8(b"TT");
        let max_supply = 10000000000000000;
        let decimals = 8;
        let icon_uri = string::utf8(b"[invalid url, do not cite]");
        let project_uri = string::utf8(b"[invalid url, do not cite]");

        let token_addr = token_factory::create_token(admin, name, symbol, max_supply, decimals, icon_uri, project_uri);
        let metadata_obj = object::address_to_object<Metadata>(token_addr);
        let payment_amount = 1000000000; // 10 APT
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(admin);
        coin::deposit(buyer_addr, coin::mint<AptosCoin>(payment_amount, &mint_cap));

        let token_amount = token_factory::buy(&buyer, token_addr, buyer_addr, payment_amount);
        assert!(token_amount > 0, 1);

        let balance = primary_fungible_store::balance(buyer_addr, metadata_obj);
        assert!(balance > 0, 2);

        let apt_balance = token_factory::get_apt_balance();
        assert!(apt_balance == payment_amount, 3);
    }

    #[test(admin = @0x1)]
    fun test_sell_token(admin: &signer) acquires token_factory::FinancialData, token_factory::CompetitionData, token_factory::FAController {
        init_for_testing(admin);
        let seller = account::create_account_for_test(@0x123);
        let seller_addr = signer::address_of(&seller);

        let name = string::utf8(b"TestToken");
        let symbol = string::utf8(b"TT");
        let max_supply = 10000000000000000;
        let decimals = 8;
        let icon_uri = string::utf8(b"[invalid url, do not cite]");
        let project_uri = string::utf8(b"[invalid url, do not cite]");

        let token_addr = token_factory::create_token(admin, name, symbol, max_supply, decimals, icon_uri, project_uri);
        let metadata_obj = object::address_to_object<Metadata>(token_addr);

        let initial_apt = 1000000000; // 10 APT

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(admin);
        coin::deposit(seller_addr, coin::mint<AptosCoin>(initial_apt, &mint_cap));

        let buy_amount = 500000000; // 5 APT
        let token_amount_bought = token_factory::buy(&seller, token_addr, seller_addr, buy_amount);
        assert!(token_amount_bought > 0, 1);

        let balance_before = primary_fungible_store::balance(seller_addr, metadata_obj);
        assert!(balance_before > 0, 2);

        let sell_amount = balance_before / 2;
        let apt_refunded = token_factory::sell(&seller, token_addr, sell_amount, seller_addr);
        assert!(apt_refunded > 0, 3);

        let balance_after = primary_fungible_store::balance(seller_addr, metadata_obj);
        assert!(balance_after == balance_before - sell_amount, 4);

        let final_apt = coin::balance<AptosCoin>(seller_addr);


        let fee_percent =token_factory::get_fee_percent(signer::address_of(admin));
        let fee = token_factory::calculate_fee(buy_amount, fee_percent);
        assert!(final_apt > initial_apt - buy_amount + apt_refunded - fee, 5);
    }

    #[test(admin = @0x1)]
    fun test_admin_set_fee_percent(admin: &signer) acquires token_factory::FinancialData {
        init_for_testing(admin);
        let new_fee = 100;
        token_factory::set_fee_percent(admin, new_fee);
        let fee_percent =token_factory::get_fee_percent(signer::address_of(admin));
        assert!(fee_percent == new_fee, 1);
    }

    #[test(non_admin = @0x123)]
    #[expected_failure(abort_code = token_factory::ERR_NOT_ADMIN)]
    fun test_set_fee_percent_non_admin_fails(non_admin: &signer) acquires token_factory::FinancialData {
        init_for_testing(non_admin);
        token_factory::set_fee_percent(non_admin, 100);
    }

    #[test(admin = @0x1)]
    fun test_admin_set_required_collateral(admin: &signer) acquires token_factory::FinancialData {
        init_for_testing(admin);
        let new_collateral = 1000;
        token_factory::set_required_collateral(admin, new_collateral);
        let required_collateral =token_factory::get_required_collateral();
        assert!(required_collateral == new_collateral, 1);
    }

    #[test(non_admin = @0x123)]
    #[expected_failure(abort_code = token_factory::ERR_NOT_ADMIN)]
    fun test_set_required_collateral_non_admin_fails(non_admin: &signer) acquires token_factory::FinancialData {
        init_for_testing(non_admin);
        token_factory::set_required_collateral(non_admin, 1000);
    }

    #[test(admin = @0x1)]
    fun test_admin_set_new_competition(admin: &signer) acquires token_factory::CompetitionData {
        init_for_testing(admin);
        let initial_id = token_factory::get_current_competition_id();
        token_factory::set_new_competition(admin);
        let new_id = token_factory::get_current_competition_id();
        assert!(new_id == initial_id + 1, 1);
    }

    #[test(non_admin = @0x123)]
    #[expected_failure(abort_code = token_factory::ERR_NOT_ADMIN)]
    fun test_set_new_competition_non_admin_fails(non_admin: &signer) acquires token_factory::CompetitionData {
        init_for_testing(non_admin);
        token_factory::set_new_competition(non_admin);
    }

    #[test(admin = @0x1, buyer = @0x123)]
    #[expected_failure(abort_code = token_factory::ERR_APT_NOT_ENOUGH)]
    fun test_buy_insufficient_apt(admin: &signer, buyer: &signer) acquires token_factory::FinancialData, token_factory::CompetitionData, token_factory::FAController {
        init_for_testing(admin);
        let buyer_addr = signer::address_of(buyer);
        let name = string::utf8(b"TestToken");
        let symbol = string::utf8(b"TT");
        let max_supply = 10000000000000000;
        let decimals = 8;
        let icon_uri = string::utf8(b"[invalid url, do not cite]");
        let project_uri = string::utf8(b"[invalid url, do not cite]");

        let token_addr = token_factory::create_token(admin, name, symbol, max_supply, decimals, icon_uri, project_uri);
        token_factory::buy(buyer, token_addr, buyer_addr, 1000000000); // No APT deposited
    }

    #[test(admin = @0x1, seller = @0x123)]
    #[expected_failure(abort_code = token_factory::ERR_APT_NOT_ENOUGH)]
    fun test_sell_insufficient_tokens(admin: &signer, seller: &signer) acquires token_factory::FinancialData, token_factory::CompetitionData, token_factory::FAController {
        init_for_testing(admin);
        let seller_addr = signer::address_of(seller);
        let name = string::utf8(b"TestToken");
        let symbol = string::utf8(b"TT");
        let max_supply = 10000000000000000;
        let decimals = 8;
        let icon_uri = string::utf8(b"[invalid url, do not cite]");
        let project_uri = string::utf8(b"[invalid url, do not cite]");

        let token_addr = token_factory::create_token(admin, name, symbol, max_supply, decimals, icon_uri, project_uri);
        token_factory::sell(seller, token_addr, 1000000000, seller_addr); // No tokens bought
    }
}