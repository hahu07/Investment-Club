module invest_platform::token {
    use invest_platform::platform;
    use aptos_framework::account;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::function_info;
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata, FungibleAsset, FungibleStore};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use std::option;
    use std::signer;
    use std::string::{Self, utf8};
    use std::vector;
    use std::error;
    use aptos_framework::chain_id;
    use aptos_framework::primary_fungible_store::{primary_store_exists, primary_store, ensure_primary_store_exists};
    use aptos_framework::timestamp;

    /// Caller is not authorized to make this call
    const E_UNAUTHORIZED: u64 = 1;
    /// No operations are allowed when contract is paused
    const E_PAUSED: u64 = 2;
    /// The account is already a minter
    const E_ALREADY_MINTER: u64 = 3;
    /// The account is not a minter
    const E_NOT_MINTER: u64 = 4;
    /// The account is denylisted
    const E_BLACKLISTED: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_DENYLISTED: u64 = 7;
    const E_WITHDRAWAL_LIMIT_EXCEEDED: u64 = 8;
    const  E_INSUFFICIENT_TOKEN_BALANCE: u64 = 9;
    const E_NOT_OWNWER:u64 = 10;

    const TOKEN_SYMBOL: vector<u8> = b"DINAR";
    const ONE_DAY_IN_SECONDS: u64 = 86400; // One day in seconds

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Roles has key {
        master_minter: address,
        minters: vector<address>,
        pauser: address,
        denylister: address,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Management has key {
        extend_ref: ExtendRef,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct State has key {
        paused: bool,          // Overall pause state
        mint_paused: bool,     // Minting paused state
        transfer_paused: bool, // Transferring paused state
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FreezeInfo has key {
        frozen_until: u64, // Timestamp until which the account is frozen
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct CashPrice has key {
        price: u64,
    }

    struct WithdrawalLimit has key {
        limit: u64,                  // The maximum amount that can be withdrawn
        current_withdrawn: u64,     // The total withdrawn amount so far
        last_reset_timestamp: u64,   // The last time the limit was reset
    }

    struct Approval has drop {
        owner: address,
        nonce: u64,
        chain_id: u8,
        spender: address,
        amount: u64,
    }

    #[event]
    struct Mint has drop, store {
        minter: address,
        to: address,
        amount: u64,
    }

    #[event]
    struct Burn has drop, store {
        minter: address,
        from: address,
        store: Object<FungibleStore>,
        amount: u64,
    }

    #[event]
    struct Pause has drop, store {
        pauser: address,
        is_paused: bool,
    }

    #[event]
    struct Denylist has drop, store {
        denylister: address,
        account: address,
    }

    #[event]
    struct RemoveMinter has drop, store {
        manager: address,
        removed_minter: address,
    }

    #[event]
    struct AddMinter has drop, store {
        manager: address,
        added_minter: address,
    }

    #[event]
    struct BalanceUpdated has drop, store {
        store: address,
        new_balance: u64,
    }

    #[event]
    struct Withdrawal {
    from: address,
    amount: u64,
    }

    fun init_module(token_signer: &signer) {
        let constructor_ref = &object::create_named_object(token_signer, TOKEN_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(TOKEN_SYMBOL),
            utf8(TOKEN_SYMBOL),
            8,
            utf8(b"http://amanatrade.com/favicon.ico"),
            utf8(b"http://amanatrade.com"),
        );

        fungible_asset::set_untransferable(constructor_ref);

        let metadata_object_signer = &object::generate_signer(constructor_ref);
        move_to(metadata_object_signer, Roles {
            master_minter: @master_minter,
            minters: vector[@minter],
            pauser: @pauser,
            denylister: @denylister,
        });

        move_to(metadata_object_signer, Management {
            extend_ref: object::generate_extend_ref(constructor_ref),
            mint_ref: fungible_asset::generate_mint_ref(constructor_ref),
            burn_ref: fungible_asset::generate_burn_ref(constructor_ref),
            transfer_ref: fungible_asset::generate_transfer_ref(constructor_ref),
        });

        let metadata_object_signer = &object::generate_signer(constructor_ref);
        move_to(metadata_object_signer, CashPrice {
            price: 5,
        });

        move_to(metadata_object_signer, State {
            paused: false,
            mint_paused: false,
            transfer_paused: false,
        });

        move_to(metadata_object_signer, WithdrawalLimit {
            limit: 0,
            current_withdrawn: 0,
            last_reset_timestamp: 0
        });

        // Override the deposit and withdraw functions which mean overriding transfer.
        // This ensures all transfer will call withdraw and deposit functions in this module and perform the necessary
        // checks.
        let deposit = function_info::new_function_info(
            token_signer,
            string::utf8(b"token"),
            string::utf8(b"deposit"),
        );
        let withdraw = function_info::new_function_info(
            token_signer,
            string::utf8(b"token"),
            string::utf8(b"withdraw"),
        );
        dispatchable_fungible_asset::register_dispatch_functions(
            constructor_ref,
            option::some(withdraw),
            option::some(deposit),
            option::none(),
        );
    }

    /// Deposit function override to ensure that the account is not denylisted and the token is not paused.
    public fun deposit<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) acquires State, FreezeInfo{
        assert_not_paused();
        assert_not_denylisted(object::owner(store));
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    public fun withdraw<T: key>(
        owner: &signer,
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ) acquires State, FreezeInfo, WithdrawalLimit {
        let owner_addr = signer::address_of(owner);
        assert!(object::owner(store)== owner_addr, E_NOT_OWNWER);

        // Ensure the contract is not paused and the account is not denylisted
        assert_not_paused();
        assert_not_denylisted(object::owner(store));

        // check the available token balance in the fungible store
        let store_balance = balance(owner_addr, store);
        assert!(amount <= store_balance, E_INSUFFICIENT_TOKEN_BALANCE);

        // Check if the withdrawal limit needs resetting
        reset_withdrawal_limits(store);

       // Fetch the withdrawal limit for the store
       let limit_info = borrow_global_mut<WithdrawalLimit>(object::owner(store));

       // Check if the withdrawal amount exceeds the limit
       assert!(limit_info.current_withdrawn + amount <= limit_info.limit, E_WITHDRAWAL_LIMIT_EXCEEDED);

       // Update the current withdrawn amount before external call
       limit_info.current_withdrawn = limit_info.current_withdrawn + amount;

       // Proceed with the withdrawal
       let asset = fungible_asset::withdraw_with_ref(transfer_ref, store, amount);

        // Emit an event for auditing purposes (optional, based on your requirements)
        event::emit(Withdrawal {
        from: object::owner(store),
        amount,
        });
    }
    
    public entry fun mint(manager: &signer, to: address, amount: u64) acquires Management, Roles, State, FreezeInfo {
        assert_is_minter(manager);
        assert!(!borrow_global<State>(token_address()).mint_paused, E_PAUSED); // Check if minting is paused
        assert_not_paused();
        assert_not_denylisted(to);
        if (amount == 0) { return };

        let roles = borrow_global<Roles>(token_address());
        assert!(signer::address_of(manager) == roles.master_minter, E_UNAUTHORIZED);

        let management = borrow_global<Management>(token_address());
        let tokens = fungible_asset::mint(&management.mint_ref, amount);
        // Ensure not to call pfs::deposit or dfa::deposit directly in the module.
        deposit(primary_fungible_store::ensure_primary_store_exists(to, metadata()), tokens, &management.transfer_ref);

        event::emit(Mint {
            minter: signer::address_of(manager),
            to,
            amount,
        });
    }

    public entry fun denylist(denylister: &signer, account: address) acquires Management, Roles, State {
        assert_not_paused();
        let roles = borrow_global<Roles>(token_address());
        assert!(signer::address_of(denylister) == roles.denylister, E_UNAUTHORIZED);

        let freeze_ref = &borrow_global<Management>(token_address()).transfer_ref;

        // Set the freeze period
        let duration = 3600 * 24 * 365;
        let freeze_until = timestamp::now_seconds() + duration;
        primary_fungible_store::set_frozen_flag(freeze_ref, account, true);

        // Store the freeze information
        move_to(denylister, FreezeInfo { frozen_until: freeze_until });

        event::emit(Denylist {
            denylister: signer::address_of(denylister),
            account,
        });
    }

    public entry fun nondenylist(denylister: &signer, account: address) acquires Management, Roles, State {
        assert_not_paused();
        let roles = borrow_global<Roles>(token_address());
        assert!(signer::address_of(denylister) == roles.denylister, E_UNAUTHORIZED);

        let freeze_ref = &borrow_global<Management>(token_address()).transfer_ref;
        primary_fungible_store::set_frozen_flag(freeze_ref, account, false);

        // Remove freeze info
        move_to(denylister, FreezeInfo { frozen_until: 0 });

        event::emit(Denylist {
            denylister: signer::address_of(denylister),
            account,
        });
    }

    /// Set the paused state for minting or transferring. Only the master minter can call this.
    public entry fun set_partial_pause(manager: &signer, mint_paused: bool, transfer_paused: bool) acquires Roles, State {
        let roles = borrow_global<Roles>(token_address());
        assert!(signer::address_of(manager) == roles.master_minter, E_UNAUTHORIZED);

        let state = borrow_global_mut<State>(token_address());
        state.mint_paused = mint_paused;          // Set mint paused state
        state.transfer_paused = transfer_paused;  // Set transfer paused state

        // Emit an event for logging (optional)
        event::emit(Pause {
            pauser: signer::address_of(manager),
            is_paused: mint_paused || transfer_paused, // You might want to log if any operation is paused
        });
    }

    /// Add a new minter. This checks that the caller is the master minter and the account is not already a minter.
    public entry fun add_minter(manager: &signer, minter: address) acquires Roles {
        let roles = borrow_global_mut<Roles>(token_address());
        assert!(signer::address_of(manager) == roles.master_minter, E_UNAUTHORIZED);
        assert!(!vector::contains(&roles.minters, &minter), E_ALREADY_MINTER);
        vector::push_back(&mut roles.minters, minter);

        event::emit(AddMinter {
            manager: signer::address_of(manager),
            added_minter: minter,
        });
    }

    public entry fun remove_minter(manager: &signer, minter: address) acquires Roles, State {
        assert_not_paused();
        let roles = borrow_global_mut<Roles>(token_address());  // Access roles
        assert!(signer::address_of(manager) == roles.master_minter, E_UNAUTHORIZED);  // Check for master minter

        // Check if the account is currently a minter
        assert!(vector::contains(&roles.minters, &minter), E_NOT_MINTER);
        let index = vector::index_of(&roles.minters, &minter);
        vector::remove(&mut roles.minters, index.unwrap());

        event::emit(RemoveMinter {
            manager: signer::address_of(manager),
            removed_minter: minter,
        });
    }

    fun reset_withdrawal_limits<T: key>(store: Object<T>) acquires WithdrawalLimit {
        let current_timestamp = timestamp::now_seconds();
        let limit_info = borrow_global_mut<WithdrawalLimit>(object::owner(store));

        // Check if a day has passed since the last reset
        assert!(current_timestamp - limit_info.last_reset_timestamp >= ONE_DAY_IN_SECONDS, E_WITHDRAWAL_LIMIT_EXCEEDED);
            // Reset the current withdrawn amount
            limit_info.current_withdrawn = 0;
            // Update the last reset timestamp
            limit_info.last_reset_timestamp = current_timestamp;
    }
    
    fun assert_is_minter(minter: &signer) acquires Roles {
        let roles = borrow_global<Roles>(token_address());
        let minter = signer::address_of(minter);
        assert!(minter == roles.master_minter || vector::contains(&roles.minters, &minter), E_UNAUTHORIZED);
    }

    fun assert_not_paused() acquires State {
        let state = borrow_global<State>(token_address());
        assert!(!state.paused, E_PAUSED);
    }

    fun assert_not_denylisted(account: address) acquires FreezeInfo {
        let metadata = metadata();
        if (primary_fungible_store::primary_store_exists_inlined(account, metadata)) {
            assert!(!fungible_asset::is_frozen(primary_fungible_store::primary_store_inlined(account, metadata)), E_DENYLISTED);

            // Check if the account is frozen until a certain timestamp
            let freeze_info = borrow_global<FreezeInfo>(account);
            if (aptos_framework::timestamp::now_seconds() < freeze_info.frozen_until) {
                assert!(false, E_DENYLISTED); // Account is still frozen
            }
        }
    }

    /// Retrieve the current list of minters.
    #[view]
    public fun list_minters(): vector<address> acquires Roles {
        let roles = borrow_global<Roles>(token_address());  // Access the Roles resource
        roles.minters  // Return a copy of the minters vector
    }

    #[view]
    public fun token_address(): address {
        object::create_object_address(&@invest_platform, TOKEN_SYMBOL)
    }

    #[view]
    public fun metadata(): Object<Metadata> {
        object::address_to_object(token_address())
    }

    #[view]
    public fun balance<T: key>(owner: address, store: Object<T>): u64 {
        if (primary_store_exists(owner, store)) {
            fungible_asset::balance(primary_store(owner, store))
        } else {
            0
        }
    }


}