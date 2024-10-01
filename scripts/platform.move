module invest_platform::platform {
    use std::signer;
    use std::string::String;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::object::{Self, ExtendRef, DeleteRef};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::smart_vector::{Self, SmartVector};

    friend invest_platform::token;

    const PLATFORM: vector<u8> = b"PlatformObject";
    const E_MEMBER_ALREADY_EXISTS: u64 = 1;
    const E_MEMBER_NOT_REGISTERED: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_EXCEEDS_WITHDRAWAL_LIMIT: u64 = 5;
    const E_INSUFFICIENT_BALANCE: u64 = 6;
    const E_INVALID_INVESTMENT_ID: u64 = 7;
    const MIN_LOCK_PERIOD: u64 = 60 * 60 * 24 * 120; // Minimum lock period of 120 days (in seconds)
    const WITHDRAWAL_PERIOD: u64 = 60 * 60 * 24 * 60; // 60-day period (in seconds)


    struct Member has key, store {
        total_balance: u64,
        portfolio: SmartTable<String, Investment>,
        added_at: u64,
        withdrawal_history: SmartVector<WithdrawalRecord>, // Track withdrawals in a period
    }

    struct Contribution has store {
        amount: u64,        // Amount invested in this contribution
        contributed_at: u64 // Timestamp when the contribution was made
    }

    struct Investment has key, store {
        invest_id: String,
        description: String,
        contributions: SmartVector<Contribution>, // List of contributions
        initial_value: u64,    // Sum of all contributions
        current_value: u64,    // Current total value of the investment
        invested_at: u64,    // Timestamp of the first contribution
        last_distributed_at: u64, // Track the last time profits were distributed
    }
    struct WithdrawalRecord has copy, drop, store {
        amount: u64,        // Amount withdrawn
        withdrawn_at: u64   // Timestamp of the withdrawal
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ClubRegistry has key {
        members: SmartTable<address, Member>,
        total_funds: u64,
        total_members: u64,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ObjectController has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef,
    }

    #[event]
    struct AddedMember has drop, store {
        member_addr: address,
        added_at: u64
    }

    #[event]
    struct AddedInvestment has drop, store {
        invest_id: String,
        member_addr: address,
        amount: u64,
        invested_at: u64
    }

    #[event]
    struct Withdrawal { 
        invest_id: String,
        member_addr: address,
        amount: u64, 
        withdrawn_at: u64,
    }
    
    fun init_module(manager: &signer) {
        let manager_address = signer::address_of(manager);
        let expected_manager_address = @invest_platform; // Replace with actual manager address

        if (manager_address != expected_manager_address) {
            abort(E_UNAUTHORIZED);
        };

        let members = smart_table::new();

        let constructor_ref = object::create_named_object(manager, PLATFORM);
        let obj_signer = object::generate_signer(&constructor_ref);

        let registry = ClubRegistry {
            members,
            total_funds: 0,
            total_members: 0
        };

        move_to(&obj_signer, registry);

        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);
        move_to(&obj_signer, ObjectController { extend_ref, delete_ref });
    }

    public entry fun join_club(signer: &signer) acquires ClubRegistry {
        let member_addr = signer::address_of(signer);
        let registry = borrow_global_mut<ClubRegistry>(@invest_platform);

        if (smart_table::contains(&registry.members, member_addr)) {
            abort(E_MEMBER_ALREADY_EXISTS);
        };

        let member = Member {
            total_balance: 0,
            portfolio: smart_table::new(),
            added_at: timestamp::now_seconds(),
            withdrawal_history: smart_vector::empty()
        };
        smart_table::add(&mut registry.members, member_addr, member);
        registry.total_members = registry.total_members + 1;

        event::emit(AddedMember {
            member_addr,
            added_at: timestamp::now_seconds()
        });
    }

    public entry fun create_investment(signer: &signer, invest_id: String, description: String) acquires ClubRegistry {
        let member_addr = signer::address_of(signer);
        let registry = borrow_global_mut<ClubRegistry>(@invest_platform);

        if (!smart_table::contains(&registry.members, member_addr)) {
            abort(E_MEMBER_NOT_REGISTERED);
        };

        // Ensure unique investment ID
        let member = smart_table::borrow_mut(&mut registry.members, member_addr);
        if (smart_table::contains(&member.portfolio, invest_id)) {
            abort(E_INVALID_INVESTMENT_ID); // Investment ID already exists
        };
        
        let invest = Investment {
            invest_id,
            description,
            contributions:smart_vector::empty(),
            initial_value: 0,
            current_value: 0,
            invested_at: timestamp::now_seconds(),
            last_distributed_at: timestamp::now_seconds()
        };
        smart_table::add(&mut member.portfolio, invest_id, invest);

        event::emit(AddedInvestment {
            invest_id,
            member_addr,
            amount: 0,
            invested_at: timestamp::now_seconds(),
        });
    }

    public entry fun add_investment(user: &signer, invest_id: String, amount: u64) acquires ClubRegistry {
        if (amount == 0) {
            abort(E_INVALID_AMOUNT);
        };

        let member_addr = signer::address_of(user);
        let registry = borrow_global_mut<ClubRegistry>(@invest_platform);

        if (!smart_table::contains(&registry.members, member_addr)) {
            abort(E_MEMBER_NOT_REGISTERED);
        };

        // Borrow the member associated with the address
        let member = smart_table::borrow_mut(&mut registry.members, member_addr);

        // Ensure the investment exists in the member's portfolio
        if (!smart_table::contains(&member.portfolio, invest_id)) {
            abort(E_INVALID_INVESTMENT_ID); // Investment ID does not exist
        };

        // Borrow the investment
        let invest = smart_table::borrow_mut(&mut member.portfolio, invest_id);

        let contribution = Contribution {
            amount,
            contributed_at: timestamp::now_seconds(),
        };

        // Add the new contribution to the investment
        vector::push_back(&mut invest.contributions, contribution);

        // Update the total initial value
        invest.initial_value = invest.initial_value + amount;
        invest.current_value = invest.current_value + amount;

        // Update member's total balance and the registry's total funds
        member.total_balance = member.total_balance + amount;
        registry.total_funds = registry.total_funds + amount;

        event::emit(AddedInvestment {
            invest_id,
            member_addr,
            amount,
            invested_at: timestamp::now_seconds(),
        });
    }

    public entry fun withdraw(user: &signer, invest_id: String, amount: u64) acquires ClubRegistry {
        if (amount == 0) {
            abort(E_INVALID_AMOUNT);
        };

        let member_addr = signer::address_of(user);
        let registry = borrow_global_mut<ClubRegistry>(@invest_platform);

        // Check if the member is registered
        if (!smart_table::contains(&registry.members, member_addr)) {
            abort(E_MEMBER_NOT_REGISTERED);
        };

        let member = smart_table::borrow_mut(&mut registry.members, member_addr);

        // Check if the member has enough unlocked balance
        let available_balance = calculate_available_balance(member);
        if (available_balance < amount) {
            abort(E_INSUFFICIENT_BALANCE); // Not enough unlocked funds to withdraw
        };

        // Calculate the maximum withdrawal limit for the current period
        let max_withdrawal_per_period = calculate_max_withdrawal_per_period(member);

        // Get the total amount already withdrawn in the current period
        let withdrawn_in_period = get_withdrawn_in_current_period(member);

        // Ensure the requested withdrawal does not exceed the limit for the current period
        if (withdrawn_in_period + amount > max_withdrawal_per_period) {
            abort(E_EXCEEDS_WITHDRAWAL_LIMIT); // Withdrawal exceeds maximum limit for the period
        };
        
        // Update the member's total balance and registry's total funds
        member.total_balance = member.total_balance - amount;
        registry.total_funds = registry.total_funds - amount;

        // Record the withdrawal in the member's history
        let record = WithdrawalRecord {
            amount,
            withdrawn_at: timestamp::now_seconds(),
        };
        smart_vector::push_back(&mut member.withdrawal_history, record);

        // Emit an event for the withdrawal
        event::emit(Withdrawal {
            invest_id,
            member_addr,
            amount,
            withdrawn_at: timestamp::now_seconds(),
        });
    }

    // Helper function to calculate the available balance of unlocked funds
    fun calculate_available_balance(member: &Member): u64 {
        let current_time = timestamp::now_seconds();
        let  available_balance = 0;

        // Loop through each investment in the portfolio
        smart_table::for_each_ref(&member.portfolio, |_, investment| {
        // Loop through each contribution in the investment
        smart_vector::for_each(investment.contributions, |contribution| {
        // Check if the lock period has passed for each contribution
        if (current_time - contribution.contributed_at >= MIN_LOCK_PERIOD) {
        available_balance = available_balance + contribution.amount;
        }
        });
        });

        available_balance
    }

    fun calculate_max_withdrawal_per_period(member: &Member): u64 {
        let total_balance = member.total_balance;
        let current_time = timestamp::now_seconds();

        // Calculate the time the member has spent on the platform (in months)
        let time_in_club = (current_time - member.added_at) / (60 * 60 * 24 * 30); // Time in months

        // Set a base withdrawal limit as a percentage of total balance
        let base_percentage: u64 = 10; // Start with 10% of the balance
        let time_based_increase: u64 = 2; // Increase by 2% for each month on the platform

        // Calculate the total percentage based on balance and time
        let total_percentage = base_percentage + (time_based_increase * time_in_club);

        // Calculate the maximum withdrawal limit per period based on the total percentage of the balance
        let max_withdrawal_per_period = total_balance * total_percentage / 100;

        max_withdrawal_per_period
    }

    fun get_withdrawn_in_current_period(member: &Member): u64 {
        let current_time = timestamp::now_seconds();
        let period_start = current_time - WITHDRAWAL_PERIOD;
        let total_withdrawn_in_period = 0;

        // Sum all withdrawals that occurred within the current period
        smart_vector::for_each(member.withdrawal_history, |record| {
        if (record.withdrawn_at >= period_start) {
        total_withdrawn_in_period = total_withdrawn_in_period + record.amount;
        }
        });

        total_withdrawn_in_period
    }
    
    public entry fun distribute_profits(signer: &signer, profit: u128, invest_id: String) acquires ClubRegistry {
        let member_addr = signer::address_of(signer);
        let registry = borrow_global_mut<ClubRegistry>(@invest_platform);

        // Check if the member is registered
        if (!smart_table::contains(&registry.members, member_addr)) {
            abort(E_MEMBER_NOT_REGISTERED);
        };

        // Retrieve the member and the investment from the portfolio
        let member = smart_table::borrow_mut(&mut registry.members, member_addr);
        let invest = smart_table::borrow_mut(&mut member.portfolio, invest_id);
        
        let profit = profit;

        if (profit <= 0) {
            return; // No profits to distribute
        };

        let current_time = timestamp::now_seconds();

        // Step 1: Calculate total weighted contributions using vector::fold
        let total_weight = smart_vector::fold(invest.contributions, 0, |contribution_acc, contributions |
            {
            let duration = current_time - contributions.contributed_at;
            let weight = contributions.amount * duration;
            contribution_acc + weight
        }
        );

        // Ensure there are valid contributions
        if (total_weight == 0) {
            return; // No valid contributions
        };

        // Step 2: Distribute profit using vector::map
        smart_vector::map(invest.contributions,|contributions|  {
            let duration = current_time - contributions.contributed_at;
            let weight = contributions.amount * duration;

            // Calculate the share of profit for this contribution
            let share_of_profit = (profit as u64) * weight / total_weight;

            // Optionally: Store or record the distributed profit for the member
            member.total_balance = member.total_balance + share_of_profit;
            invest.current_value = invest.current_value + share_of_profit;
        });
    }


}
