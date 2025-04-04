module apump_ai::token_factory {
    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string;
    use std::string::String;
    use aptos_std::math128;
    use aptos_std::ordered_map;
    use aptos_std::ordered_map::OrderedMap;
    use aptos_std::smart_table;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::function_info::{FunctionInfo, new_function_info};
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{TransferRef, FungibleAsset, Metadata, withdraw};
    use aptos_framework::object;
    use aptos_framework::object::{ExtendRef, Object};
    use aptos_framework::primary_fungible_store;
    use apump_ai::bonding_curve::{compute_refund_for_burning, compute_minting_amount_from_price};


    // ERROR CONSTANTS
    const ERR_NOT_ADMIN: u64 = 1;
    const ERR_EXISTS_ALREADY: u64 = 10;
    const ERR_COMPETITION_ID_ENDED: u64 = 11;
    const ERR_TOKEN_NOT_FOUND: u64 = 12;
    const ERR_APT_NOT_ENOUGH: u64 = 13;

    const ERR_MINT_LIMIT: u64 = 15;

    // GLOBAL CONSTANTS
    const FEE_DENOMINATOR: u64 = 10000;


    struct FinancialData has store, key {
        fee_percent: u64,
        fee_accumulated: u64,
        fee_withdrawn: u64,
        required_collateral: u64,
        collateral_by_id: Table<u64, Table<address, u64>>,
        apt_balance: u64,
        resource_signer_cap: account::SignerCapability,
    }

    struct CompetitionData has store, key {
        current_competition_id: u64,
        tokens_by_competition_id: OrderedMap<u64, vector<address>>,
        competition_ids: OrderedMap<address, u64>,
        winners: Table<u64, address>,
    }

    struct TokenData has store, key {
        tokens_creators: Table<address, address>,
        tokens_pools: Table<address, address>,
        liquidity_position_token_ids: Table<address, u64>,
    }

    #[event]
    struct FungibleAssetCreated has store, drop {
        name: String,
        symbol: String,
        max_supply: u128,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    }

    /// Unique per FA
    struct MintLimit has store {
        limit: u64,
        mint_tracker: Table<address, u64>,
    }

    struct FAOwnerObjConfig has key {
        // Only thing it stores is the link to FA object
        fa_obj: Object<Metadata>
    }

    /// Unique per FA
    struct FAConfig has key {
        // Mint fee per FA denominated in oapt (smallest unit of APT, i.e. 1e-8 APT)
        mint_fee_per_smallest_unit_of_fa: u64,
        mint_limit: Option<MintLimit>,
        fa_owner_obj: Object<FAOwnerObjConfig>,
    }

    struct TokenFactory has key {
        permissioned_withdraw: FunctionInfo,
        fa_generator_extend_ref: ExtendRef
    }

    struct TokenRegistry has key {
        tokens: smart_table::SmartTable<String, address>,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FAController has key, store {
        transfer_ref: TransferRef,
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
    }

    #[event]
    struct MintFAEvent has store, drop {
        fa_obj: Object<Metadata>,
        amount: u64,
        recipient_addr: address,
        total_mint_fee: u64,
    }

    #[event]
    struct FeeEvent has store, drop {
        buyer: address,
        fee_amount: u64,
        token: address,
    }

    #[event]
    struct PaymentEvent has store, drop {
        seller: address,
        receiver: address,
        amount: u64,
    }


    fun init_module(contract: &signer) {
        let (_resource, resource_signer_cap) = account::create_resource_account(contract, b"token_factory_sell");
        move_to(contract, FinancialData {
            fee_percent: 0,
            fee_accumulated: 0,
            fee_withdrawn: 0,
            required_collateral: 0,
            collateral_by_id: table::new<u64, Table<address, u64>>(),
            apt_balance: 0,
            resource_signer_cap,
        });
        move_to(contract, TokenRegistry {
            tokens: smart_table::new()
        });

        let seed = b"fa_generator";
        let constructor_ref = object::create_named_object(contract, seed);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        let permissioned_withdraw = new_function_info(
            contract,
            string::utf8(b"token_factory"),
            string::utf8(b"permissioned_withdraw")
        );

        move_to(contract, TokenFactory {
            permissioned_withdraw,
            fa_generator_extend_ref: extend_ref
        });

        let competition_data = CompetitionData {
            current_competition_id: 0,
            tokens_by_competition_id: ordered_map::new(),
            competition_ids: ordered_map::new(),
            winners: table::new()
        };
        move_to(contract, competition_data);
    }

    #[test_only]
    public fun init_for_test() {
        init_module(
            &account::create_account_for_test(@apump_ai)
        )
    }

    inline fun in_competition_check(token: address) acquires CompetitionData {
        let competition_ids = &borrow_global<CompetitionData>(@apump_ai).competition_ids;
        let current_competition_id = &borrow_global<CompetitionData>(@apump_ai).current_competition_id;
        let competion_id = competition_ids.borrow(&token);
        assert!(competion_id == current_competition_id, ERR_COMPETITION_ID_ENDED);
    }

    inline fun only_owner(admin: address) {
        assert!(admin == @apump_ai, ERR_NOT_ADMIN);
    }

    fun create_token_internal(
        name: String,
        symbol: String,
        max_supply: u128,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): (address, FungibleAsset) acquires TokenFactory {
        let does_fa_exist = object::object_exists<FAController>(get_fa_obj_address(name, symbol));
        assert!(!does_fa_exist, ERR_EXISTS_ALREADY);
        let apump = borrow_global_mut<TokenFactory>(@apump_ai);
        let fa_generator_signer = object::generate_signer_for_extending(&apump.fa_generator_extend_ref);
        let fa_key_seed = *name.bytes();
        fa_key_seed.append(b"-");
        fa_key_seed.append(*symbol.bytes());
        let fa_obj_constructor_ref = &object::create_named_object(&fa_generator_signer, fa_key_seed);
        let fa_obj_signer = object::generate_signer(fa_obj_constructor_ref);
        let base_unit_max_supply = option::some(max_supply * math128::pow(10, (decimals as u128)));

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            base_unit_max_supply,
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let fa_minted = fungible_asset::mint(&mint_ref, (max_supply as u64));

        move_to(&fa_obj_signer, FAController { transfer_ref, mint_ref, burn_ref });

        event::emit(FungibleAssetCreated { name, symbol, max_supply, decimals, icon_uri, project_uri });
        (get_fa_obj_address(name, symbol), fa_minted)
    }

    entry fun create_token_entry(
        signer: &signer,
        name: String,
        symbol: String,
        max_supply: u128,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ) acquires TokenFactory, TokenRegistry {
        create_token(
            signer,
            name,
            symbol,
            max_supply,
            decimals,
            icon_uri,
            project_uri
        );
    }


    public fun create_token(
        signer: &signer,
        name: String,
        symbol: String,
        max_supply: u128,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): address acquires TokenFactory, TokenRegistry {
        let (address, fa_minted) = create_token_internal(name, symbol, max_supply, decimals, icon_uri, project_uri);

        let signer_addr = signer::address_of(signer);
        let metadata_obj = object::address_to_object<Metadata>(address);
        let signer_store = primary_fungible_store::ensure_primary_store_exists(signer_addr, metadata_obj);
        fungible_asset::deposit(signer_store, fa_minted);

        let registry = borrow_global_mut<TokenRegistry>(@apump_ai);
        let key = string::utf8(b"");
        key.append(name);
        key.append(string::utf8(b"-"));
        key.append(symbol);
        registry.tokens.add(key, address);
        address
    }


    public entry fun buy(
        buyer: &signer,
        token: address,
        receiver: address,
        payment_amount: u64
    ) acquires CompetitionData, FinancialData, FAController {
        let competition_data = borrow_global<CompetitionData>(@apump_ai);
        let competition_id = competition_data.competition_ids.borrow(&token);
        assert!(*competition_id > 0, ERR_TOKEN_NOT_FOUND);
        assert!(payment_amount > 0, ERR_TOKEN_NOT_FOUND);

        let (payment_without_fee, fee): (u64, u64) = get_collateral_amount_and_fee(payment_amount);
        let buyer_addr = signer::address_of(buyer);
        let buyer_balance = coin::balance<AptosCoin>(buyer_addr);
        assert!(buyer_balance >= payment_amount, ERR_APT_NOT_ENOUGH);
        let coins = coin::withdraw<AptosCoin>(buyer, payment_amount);

        let financial_data = borrow_global_mut<FinancialData>(@apump_ai);
        let resource_signer = account::create_signer_with_capability(&financial_data.resource_signer_cap);
        coin::deposit<AptosCoin>(signer::address_of(&resource_signer), coins);
        financial_data.apt_balance += payment_amount;

        let token_amount = get_buy_token_amount(token, payment_without_fee);

        let fa_controller = borrow_global<FAController>(token);
        let metadata_obj: Object<Metadata> = object::address_to_object<Metadata>(token);

        let receiver_store = primary_fungible_store::ensure_primary_store_exists(receiver, metadata_obj);
        let fa = fungible_asset::mint(&fa_controller.mint_ref, (token_amount as u64));
        fungible_asset::deposit(receiver_store, fa);

        event::emit(FeeEvent {
            buyer: signer::address_of(buyer),
            fee_amount: fee,
            token
        });
    }

    public entry fun sell(
        seller: &signer,
        token: address,
        amount: u64,
        receiver: address
    ) acquires FinancialData, FAController, CompetitionData {
        let seller_addr = signer::address_of(seller);
        let fa_controller = borrow_global<FAController>(token);
        let metadata_obj = object::address_to_object<Metadata>(token);

        let balance = primary_fungible_store::balance(seller_addr, metadata_obj);
        assert!(balance >= amount, ERR_APT_NOT_ENOUGH);

        let competition_data = borrow_global<CompetitionData>(@apump_ai);
        let competition_id = *competition_data.competition_ids.borrow(&token);

        let financial_data = borrow_global_mut<FinancialData>(@apump_ai);
        let collateral_by_id_data = financial_data.collateral_by_id.borrow(competition_id);
        let collateral = collateral_by_id_data.borrow(token);
        let fa_maximum_supply = fungible_asset::maximum(metadata_obj).extract::<u128>();

        let payment = compute_refund_for_burning(*collateral as u128, fa_maximum_supply, amount as u128);
        assert!(financial_data.apt_balance >= (payment as u64), ERR_APT_NOT_ENOUGH);

        let fa = primary_fungible_store::withdraw(seller, metadata_obj, amount);
        fungible_asset::burn(&fa_controller.burn_ref, fa);

        let resource_signer = account::create_signer_with_capability(&financial_data.resource_signer_cap);
        let resource_addr = signer::address_of(&resource_signer);
        let coin_balance = coin::balance<AptosCoin>(resource_addr);
        assert!(coin_balance >= (payment as u64), ERR_APT_NOT_ENOUGH);
        coin::transfer<AptosCoin>(&resource_signer, receiver, (payment as u64));
        financial_data.apt_balance -= (payment as u64);
    }

    public entry fun set_fee_percent(admin: &signer, new_fee_percent: u64) acquires FinancialData {
        only_owner(signer::address_of(admin));
        let financial_data = borrow_global_mut<FinancialData>(@apump_ai);
        financial_data.fee_percent = new_fee_percent;
    }

    public entry fun set_required_collateral(admin: &signer, required_collateral: u64) acquires FinancialData {
        only_owner(signer::address_of(admin));
        let financial_data = borrow_global_mut<FinancialData>(@apump_ai);
        financial_data.required_collateral = required_collateral;
    }

    public entry fun set_new_competition(admin: &signer) acquires CompetitionData {
        only_owner(signer::address_of(admin));
        let competition_data = borrow_global_mut<CompetitionData>(@apump_ai);
        competition_data.current_competition_id += 1;
    }


    fun get_buy_token_amount(
        fa_address: address,
        payment_without_fee: u64
    ): u128 acquires CompetitionData, FinancialData {
        let financial_data = borrow_global<FinancialData>(@apump_ai);
        let competition_data = borrow_global<CompetitionData>(@apump_ai);
        let competition_id = competition_data.competition_ids.borrow(&fa_address);
        let collateral_by_id_data = financial_data.collateral_by_id.borrow(*competition_id);
        let collateral = collateral_by_id_data.borrow(fa_address);

        let metadata_obj: Object<Metadata> = object::address_to_object<Metadata>(fa_address);
        let fa_maximum_supply = fungible_asset::maximum(metadata_obj).extract::<u128>();

        compute_minting_amount_from_price(
            (*collateral as u128), fa_maximum_supply, (payment_without_fee as u128))
    }


    #[view]
    fun get_collateral_amount_and_fee(
        payment_amount: u64,
    ): (u64, u64) acquires FinancialData {
        let financial_data = borrow_global<FinancialData>(@apump_ai);
        let fee = calculate_fee(payment_amount, financial_data.fee_percent);
        let payment_without_fee = payment_amount - fee;
        (payment_without_fee, fee)
    }

    #[view]
    public fun get_winner_by_competition_id(competition_id: u64): address acquires CompetitionData, FinancialData {
        let max_collateral: u64 = 0;
        let winner: address = @zero;
        let competition_data = borrow_global<CompetitionData>(@apump_ai);
        let financial_data = borrow_global<FinancialData>(@apump_ai);

        let tokens_by_competition_id_vec = competition_data.tokens_by_competition_id.borrow(&competition_id);
        let collateral_by_id_data = financial_data.collateral_by_id.borrow(competition_id);
        let tokens_by_competition_length = tokens_by_competition_id_vec.length();

        let i = 0;
        while (i < tokens_by_competition_length) {
            let fa_address = tokens_by_competition_id_vec.borrow(i);
            let collateral = collateral_by_id_data.borrow(*fa_address);

            if (*collateral > max_collateral) {
                max_collateral = *collateral;
                winner = *fa_address;
            };
            i += 1;
        };

        winner
    }

    #[view]
    public fun get_collateral_by_competition_id(competition_id: u64): u64 acquires CompetitionData, FinancialData {
        let collateral_without_fee: u64 = 0;
        let winner = get_winner_by_competition_id(competition_id);

        let competition_data = borrow_global<CompetitionData>(@apump_ai);
        let tokens_by_competition_id_vec = competition_data.tokens_by_competition_id.borrow(&competition_id);
        let tokens_by_competition_length = tokens_by_competition_id_vec.length();

        let i = 0;
        while (i < tokens_by_competition_length) {
            let fa_address = *tokens_by_competition_id_vec.borrow(i);

            let financial_data = borrow_global<FinancialData>(@apump_ai);
            let collateral_by_id_data = financial_data.collateral_by_id.borrow(competition_id);
            let collateral = *collateral_by_id_data.borrow(fa_address);

            if (winner == fa_address) {
                collateral_without_fee += collateral;
            } else {
                let (payment_without_fee, _): (u64, u64) = get_collateral_amount_and_fee(collateral);
                collateral_without_fee += payment_without_fee;
            };
            i += 1;
        };

        collateral_without_fee
    }

    #[view]
    public fun get_current_minted_amount(
        fa_obj: Object<Metadata>,
        addr: address
    ): u64 acquires FAConfig {
        let fa_config = borrow_global<FAConfig>(object::object_address(&fa_obj));
        assert!(fa_config.mint_limit.is_some(), ERR_MINT_LIMIT);
        let mint_limit = fa_config.mint_limit.borrow();
        let mint_tracker = &mint_limit.mint_tracker;
        *mint_tracker.borrow_with_default(addr, &0)
    }


    #[view]
    public fun get_fa_obj_address(
        name: String,
        symbol: String
    ): address acquires TokenFactory {
        let token_factory_data = borrow_global<TokenFactory>(@apump_ai);
        let fa_generator_address = object::address_from_extend_ref(&token_factory_data.fa_generator_extend_ref);
        let fa_key_seed = *name.bytes();
        fa_key_seed.append(b"-");
        fa_key_seed.append(*symbol.bytes());
        object::create_object_address(&fa_generator_address, fa_key_seed)
    }

    #[view]
    public fun get_fee_percent(account: address): u64 acquires FinancialData {
        let financial_data = borrow_global<FinancialData>(account);
        financial_data.fee_percent
    }


    #[view]
    public fun calculate_fee(amount: u64, fee_percent: u64): u64 {
        ((amount * fee_percent) / FEE_DENOMINATOR)
    }

    #[view]
    public fun get_apt_balance(): u64 acquires FinancialData {
        borrow_global<FinancialData>(@apump_ai).apt_balance
    }

    #[view]
    public fun get_required_collateral(): u64 acquires FinancialData {
        borrow_global<FinancialData>(@apump_ai).required_collateral
    }

    #[view]
    public fun get_current_competition_id(): u64 acquires CompetitionData {
        borrow_global<CompetitionData>(@apump_ai).current_competition_id
    }

    #[view]
    public fun get_fa_collection(): vector<address> acquires TokenRegistry {
        let vec = vector[];
        TokenRegistry[@apump_ai].tokens.for_each_ref(|k, v|{
            vec.push_back(*v);
        });
        vec
    }
}