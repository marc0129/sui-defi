module interest_protocol::whirpool {
  use std::ascii::{String};
  use std::vector;
  
  use sui::tx_context::{Self, TxContext};
  use sui::transfer;
  use sui::object::{Self, UID};
  use sui::bag::{Self, Bag};
  use sui::table::{Self, Table};
  use sui::balance::{Self, Balance};
  use sui::coin::{Self, Coin};
  use sui::pay;
  use sui::math;

  use interest_protocol::ipx::{Self, IPX, IPXStorage};
  use interest_protocol::dnr::{Self, DNR, DineroStorage};
  use interest_protocol::interest_rate_model::{Self, InterestRateModelStorage};
  use interest_protocol::oracle::{Self, OracleStorage};
  use interest_protocol::utils::{get_coin_info};
  use interest_protocol::rebase::{Self, Rebase};
  use interest_protocol::math::{fmul, fdiv, one};

  const INITIAL_RESERVE_FACTOR_MANTISSA: u64 = 200000000; // 0.2e9 or 20%
  const INITIAL_IPX_PER_EPOCH: u64 = 100000000000; // 100 IPX per epoch
  const TWENTY_FIVE_PER_CENT: u64 = 25000000; 

  const ERROR_DEPOSIT_NOT_ALLOWED: u64 = 1;
  const ERROR_WITHDRAW_NOT_ALLOWED: u64 = 2;
  const ERROR_NOT_ENOUGH_CASH_TO_WITHDRAW: u64 = 3;
  const ERROR_NOT_ENOUGH_CASH_TO_LEND: u64 = 4;
  const ERROR_BORROW_NOT_ALLOWED: u64 = 5;
  const ERROR_REPAY_NOT_ALLOWED: u64 = 6;
  const ERROR_MARKET_IS_PAUSED: u64 = 7;
  const ERROR_MARKET_NOT_UP_TO_DATE: u64 = 8;
  const ERROR_BORROW_CAP_LIMIT_REACHED: u64 = 9;
  const ERROR_ZERO_ORACLE_PRICE: u64 = 10;
  const ERROR_MARKET_EXIT_LOAN_OPEN: u64 = 11;
  const ERROR_USER_IS_INSOLVENT: u64 = 12;
  const ERROR_NOT_ENOUGH_RESERVES: u64 = 13;
  const ERROR_CAN_NOT_USE_DNR: u64 = 14;
  const ERROR_DNR_OPERATION_NOT_ALLOWED: u64 = 15;
  const ERROR_USER_IS_SOLVENT: u64 = 16;
  const ERROR_ACCOUNT_COLLATERAL_DOES_EXIST: u64 = 17;
  const ERROR_ACCOUNT_LOAN_DOES_EXIST: u64 = 18;
  const ERROR_ZERO_LIQUIDATION_AMOUNT: u64 = 19;
  const ERROR_LIQUIDATOR_IS_BORROWER: u64 = 20;
  const ERROR_MAX_COLLATERAL_REACHED: u64 = 21;
  const ERROR_NOT_ENOUGH_SHARES_IN_THE_ACCOUNT: u64 = 22;
  const ERROR_VALUE_TOO_HIGH: u64 = 23;
  const ERROR_NO_ADDRESS_ZERO: u64 = 24;

  struct WhirpoolAdminCap has key {
    id: UID
  }

  struct MarketData has key, store {
    id: UID,
    total_reserves: u64,
    accrued_epoch: u64,
    borrow_cap: u64,
    collateral_cap: u64,
    balance_value: u64, // cash
    is_paused: bool,
    ltv: u64,
    reserve_factor: u64,
    allocation_points: u64,
    accrued_collateral_rewards_per_share: u256,
    accrued_loan_rewards_per_share: u256,
    collateral_rebase: Rebase,
    loan_rebase: Rebase,
    decimals_factor: u64
  }

  struct MarketBalance<phantom T> has key, store {
    id: UID,
    balance: Balance<T>
  }

  struct Liquidation has key, store {
    id: UID,
    penalty_fee: u64,
    protocol_percentage: u64
  }

  struct WhirpoolStorage has key {
    id: UID,
    market_data_table: Table<String, MarketData>,
    liquidation_table: Table<String, Liquidation>,
    all_markets_keys: vector<String>,
    market_balance_bag: Bag, // get_coin_info -> MarketTokens,
    total_allocation_points: u64,
    ipx_per_epoch: u64
  }

  struct Account has key, store {
    id: UID,
    principal: u64,
    shares: u64,
    collateral_rewards_paid: u256,
    loan_rewards_paid: u256
  }

  struct AccountStorage has key {
     id: UID,
     accounts_table: Table<String, Table<address, Account>>, // get_coin_info -> address -> Account
     markets_in_table: Table<address, vector<String>>  
  }

  fun init(ctx: &mut TxContext) {
    transfer::transfer(
      WhirpoolAdminCap {
        id: object::new(ctx)
      },
      tx_context::sender(ctx)
    );

    transfer::share_object(
      WhirpoolStorage {
        id: object::new(ctx),
        market_data_table: table::new(ctx),
        liquidation_table: table::new(ctx),
        all_markets_keys: vector::empty(),
        market_balance_bag: bag::new(ctx),
        total_allocation_points: 0,
        ipx_per_epoch: INITIAL_IPX_PER_EPOCH
      }
    );

    transfer::share_object(
      AccountStorage {
        id: object::new(ctx),
        accounts_table: table::new(ctx),
        markets_in_table: table::new(ctx)
      }
    );
  }

  /**
  * TODO - UPDATE TO TIMESTAMPS
  * @notice It updates the loan and rewards information for the MarketData with collateral Coin<T> to the latest epoch.
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared storage object of ipx::interest_rate_model
  * @param dinero_storage The shared storage object of ipx::dnr 
  */
  public fun accrue<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    interest_rate_model_storage: &InterestRateModelStorage, 
    dinero_storage: &DineroStorage,
    ctx: &TxContext
  ) {
    // Save storage information before mutation
    let market_key = get_coin_info<T>(); // Key of the current market being updated
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch; // IPX mint amount per epoch
    let total_allocation_points = whirpool_storage.total_allocation_points; // Total allocation points

    accrue_internal(
      borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key), 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );
  }

  /**
  * @notice It allows a user to deposit Coin<T> in a market as collateral. Other users can borrow this coin for a fee. User can use this collateral to borrow coins from other markets. 
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param asset The Coin<T> the user is depositing
  * @return Coin<IPX> It will mint IPX rewards to the user.
  * Requirements: 
  * - The market is not paused
  * - The collateral cap has not been reached
  */
  public fun deposit<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &DineroStorage,
    asset: Coin<T>,
    ctx: &mut TxContext
  ): Coin<IPX> {
      // Get the type name of the Coin<T> of this market.
      let market_key = get_coin_info<T>();
      // User cannot use DNR as collateral
      assert!(market_key != get_coin_info<DNR>(), ERROR_DNR_OPERATION_NOT_ALLOWED);

      // Reward information in memory
      let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
      let total_allocation_points = whirpool_storage.total_allocation_points;
      
      // Get market core information
      let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);
      let market_balance = borrow_mut_market_balance<T>(&mut whirpool_storage.market_balance_bag, market_key);

      // Save the sender address in memory
      let sender = tx_context::sender(ctx);

      // We need to register his account on the first deposit call, if it does not exist.
      init_account(account_storage, sender, market_key, ctx);

      // We need to update the market loan and rewards before accepting a deposit
      accrue_internal(
        market_data, 
        interest_rate_model_storage, 
        dinero_storage, 
        market_key, 
        ipx_per_epoch,
        total_allocation_points,
        ctx
      );

      // Declare the pending rewards variable that will save the value of Coin<IPX> to mint.
      let pending_rewards = 0;

      // Get the caller Account to update
      let account = borrow_mut_account(account_storage, sender, market_key);

      // If the sender has shares already, we need to calculate his rewards before this deposit.
      if (account.shares > 0) 
        // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
        pending_rewards = (
          (account.shares as u256) * 
          market_data.accrued_collateral_rewards_per_share / 
          (market_data.decimals_factor as u256)) - 
          account.collateral_rewards_paid;
      
      // Save the value of the coin being deposited in memory
      let asset_value = coin::value(&asset);

      // Update the collateral rebase. 
      // We round down to give the edge to the protocol
      let shares = rebase::add_elastic(&mut market_data.collateral_rebase, asset_value, false);

      // Deposit the Coin<T> in the market
      balance::join(&mut market_balance.balance, coin::into_balance(asset));
      // Update the amount of cash in the market
      market_data.balance_value = market_data.balance_value + asset_value;

      // Assign the additional shares to the sender
      account.shares = account.shares + shares;
      // Consider all rewards earned by the sender paid
      account.collateral_rewards_paid = (account.shares as u256) * market_data.accrued_collateral_rewards_per_share / (market_data.decimals_factor as u256);

      // Check hook after all mutations
      assert!(deposit_allowed(market_data), ERROR_DEPOSIT_NOT_ALLOWED);
      // Mint Coin<IPX> to the user.
      mint_ipx(ipx_storage, pending_rewards, ctx)
  }  

  /**
  * @notice It allows a user to withdraw his shares of Coin<T>.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle
  * @param shares_to_remove The number of shares the user wishes to remove
  * @return (Coin<T>, Coin<IPX>)
  * Requirements: 
  * - Market is not paused 
  * - User is solvent after withdrawing Coin<T> collateral
  */
  public fun withdraw<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &DineroStorage,
    oracle_storage: &OracleStorage,
    shares_to_remove: u64,
    ctx: &mut TxContext
  ): (Coin<T>, Coin<IPX>) {
    // Get the type name of the Coin<T> of this market.
    let market_key = get_coin_info<T>();
    // User cannot use DNR as collateral
    assert!(market_key != get_coin_info<DNR>(), ERROR_DNR_OPERATION_NOT_ALLOWED);

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);
    let market_balance = borrow_mut_market_balance<T>(&mut whirpool_storage.market_balance_bag, market_key);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // Save the sender info in memory
    let sender = tx_context::sender(ctx);

    // Get the sender account struct
    let account = borrow_mut_account(account_storage, sender, market_key);
    // No point to proceed if the sender does not have any shares to withdraw.
    assert!(account.shares >= shares_to_remove, ERROR_NOT_ENOUGH_SHARES_IN_THE_ACCOUNT);
    
    // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
    let pending_rewards = ((account.shares as u256) * 
          market_data.accrued_collateral_rewards_per_share / 
          (market_data.decimals_factor as u256)) - 
          account.collateral_rewards_paid;
    
    // Update the base and elastic of the collateral rebase
    // Round down to give the edge to the protocol
    let underlying_to_redeem = rebase::sub_base(&mut market_data.collateral_rebase, shares_to_remove, false);

    // Market must have enough cash or there is no point to proceed
    assert!(market_data.balance_value >= underlying_to_redeem , ERROR_NOT_ENOUGH_CASH_TO_WITHDRAW);

    // Reduce the amount of cash in the market
    market_data.balance_value = market_data.balance_value - underlying_to_redeem;

    // Remove the shares from the sender
    account.shares = account.shares - shares_to_remove;
    // Consider all rewards earned by the sender paid
    account.collateral_rewards_paid = (account.shares as u256) * market_data.accrued_collateral_rewards_per_share / (market_data.decimals_factor as u256);

    // Remove Coin<T> from the market
    let underlying_coin = coin::take(&mut market_balance.balance, underlying_to_redeem, ctx);

    // Check should be the last action after all mutations
    assert!(withdraw_allowed(
      &mut whirpool_storage.market_data_table, 
      account_storage, oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage, 
      ipx_per_epoch,
      total_allocation_points,
      market_key, 
      sender, 
      underlying_to_redeem, 
      ctx
     ), 
    ERROR_WITHDRAW_NOT_ALLOWED);

    // Return Coin<T> and Coin<IPX> to the sender
    (underlying_coin, mint_ipx(ipx_storage, pending_rewards, ctx))
  }

  /**
  * @notice It allows a user to borrow Coin<T>.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param borrow_value The value of Coin<T> the user wishes to borrow
  * @return (Coin<T>, Coin<IPX>)
  * Requirements: 
  * - Market is not paused 
  * - User is solvent after borrowing Coin<T> collateral
  * - Market borrow cap has not been reached
  */
  public fun borrow<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &DineroStorage,
    oracle_storage: &OracleStorage,
    borrow_value: u64,
    ctx: &mut TxContext
  ): (Coin<T>, Coin<IPX>) {
    // Get the type name of the Coin<T> of this market.
    let market_key = get_coin_info<T>();
    // User cannot use DNR as collateral
    assert!(market_key != get_coin_info<DNR>(), ERROR_DNR_OPERATION_NOT_ALLOWED);

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);
    let market_balance = borrow_mut_market_balance<T>(&mut whirpool_storage.market_balance_bag, market_key);

    // There is no point to proceed if the market does not have enough cash
    assert!(market_data.balance_value >= borrow_value, ERROR_NOT_ENOUGH_CASH_TO_LEND);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // Save the sender address in memory
    let sender = tx_context::sender(ctx);

    // Init the acount if the user never borrowed or deposited in this market
    init_account(account_storage, sender, market_key, ctx);

    // Register market in vector if the user never entered any market before
    init_markets_in(account_storage, sender);

    // Get the user account
    let account = borrow_mut_account(account_storage, sender, market_key);

    let pending_rewards = 0;
    // If the sender has a loan already, we need to calculate his rewards before this loan.
    if (account.principal > 0) 
      // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
      pending_rewards = (
        (account.principal as u256) * 
        market_data.accrued_loan_rewards_per_share / 
        (market_data.decimals_factor as u256)) - 
        account.loan_rewards_paid;

    // Update the loan rebase with the new loan
    let borrow_principal = rebase::add_elastic(&mut market_data.loan_rebase, borrow_value, true);

    // Update the principal owed by the sender
    account.principal = account.principal + borrow_principal; 
    // Consider all rewards paid
    account.loan_rewards_paid = (account.principal as u256) * market_data.accrued_loan_rewards_per_share / (market_data.decimals_factor as u256);
    // Reduce the cash of the market
    market_data.balance_value = market_data.balance_value - borrow_value;

    // Remove Coin<T> from the market
    let loan_coin = coin::take(&mut market_balance.balance, borrow_value, ctx);

    // Check should be the last action after all mutations
    assert!(borrow_allowed(
      &mut whirpool_storage.market_data_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage,
      ipx_per_epoch,
      total_allocation_points, 
      market_key, 
      sender, 
      borrow_value, 
      ctx), 
    ERROR_BORROW_NOT_ALLOWED);

    (loan_coin, mint_ipx(ipx_storage, pending_rewards, ctx))
  }

  /**
  * @notice It allows a user repay his principal with Coin<T>.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param asset The Coin<T> he is repaying. 
  * @param principal_to_repay The principal he wishes to repay
  * @return Coin<IPX> rewards
  * Requirements: 
  * - Market is not paused 
  */
  public fun repay<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &DineroStorage,
    asset: Coin<T>,
    principal_to_repay: u64,
    ctx: &mut TxContext
  ): Coin<IPX> {
    // Get the type name of the Coin<T> of this market.
    let market_key = get_coin_info<T>();
    // User cannot use DNR as collateral
    assert!(market_key != get_coin_info<DNR>(), ERROR_DNR_OPERATION_NOT_ALLOWED);

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);
    let market_balance = borrow_mut_market_balance<T>(&mut whirpool_storage.market_balance_bag, market_key);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );
    
    // Save the sender in memory
    let sender = tx_context::sender(ctx);

    // Get the sender account
    let account = borrow_mut_account(account_storage, sender, market_key);

    // Calculate the sender rewards before repayment
    // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
    let pending_rewards = (
        (account.principal as u256) * 
        market_data.accrued_loan_rewards_per_share / 
        (market_data.decimals_factor as u256)) - 
        account.loan_rewards_paid;

    // Save the value of Coin<T> in memory
    let asset_value = coin::value(&asset);

    // Convert asset_value to principal
    let asset_principal = rebase::to_base(&market_data.loan_rebase, asset_value, false);

    // Ensure that the user is not overpaying his loan. This is important because interest rate keeps accrueing every second.
    // Users will usually send more Coin<T> then needed
    let safe_asset_principal = if (asset_principal > account.principal) { math::min(account.principal, principal_to_repay) } else { math::min(asset_principal, principal_to_repay) };

    // Convert the safe principal to Coin<T> value so we can send any extra back to the user
    let repay_amount = rebase::to_elastic(&market_data.loan_rebase, safe_asset_principal, true);

    // If the sender send more Coin<T> then necessary, we return the extra to him
    if (asset_value > repay_amount) pay::split_and_transfer(&mut asset, asset_value - repay_amount, sender, ctx);

    // Deposit Coin<T> in the market
    balance::join(&mut market_balance.balance, coin::into_balance(asset));
    // Increase the cash in the market
    market_data.balance_value = market_data.balance_value + repay_amount;

    // Remove the principal repaid from the user account
    account.principal = account.principal - safe_asset_principal;
    // Consider all rewards paid
    account.loan_rewards_paid = (account.principal as u256) * market_data.accrued_loan_rewards_per_share / (market_data.decimals_factor as u256);
    assert!(repay_allowed(market_data), ERROR_REPAY_NOT_ALLOWED);
    mint_ipx(ipx_storage, pending_rewards, ctx)
  }
  
  /**
  * TODO Update to use timestamps
  * @notice It returns the current interest rate per epoch
  * @param whirpool_storage The shared storage object of the ipx::whirpool module 
  * @param interest_rate_model_storage The shared storage object of the ipx::interest_rate_model 
  * @param dinero_storage The shared storage object of the ipx::dnr
  * @return interest rate per epoch % for MarketData of Coin<T>
  */
  public fun get_borrow_rate_per_epoch<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    ): u64 {
    let market_key = get_coin_info<T>();
    get_borrow_rate_per_epoch_internal(
      borrow_market_data(&mut whirpool_storage.market_data_table, market_key),
      interest_rate_model_storage,
      dinero_storage,
      market_key
    )
  }

  /**
  * TODO Update to use timestamps
  * @notice It returns the current interest rate per epoch
  * @param market_data The MarketData struct of Market for Coin<T>
  * @param interest_rate_model_storage The shared storage object of the ipx::interest_rate_model 
  * @param dinero_storage The shared storage object of the ipx::dnr
  * @param market_key The key of the market
  * @return interest rate per epoch % for MarketData of Coin<T>
  */
  fun get_borrow_rate_per_epoch_internal(
    market_data: &MarketData, 
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    market_key: String,
    ): u64 {
      // DNR has a constant interest_rate
      if (get_coin_info<DNR>() == market_key) {
        dnr::get_interest_rate_per_epoch(dinero_storage)
      } else {
       // Other coins follow the start jump rate interest rate model 
        interest_rate_model::get_borrow_rate_per_epoch(
          interest_rate_model_storage,
          market_key,
          market_data.balance_value,
          rebase::elastic(&market_data.loan_rebase),
          market_data.total_reserves
        )
      }
  }

  /**
  * TODO Update to use timestamps
  * @notice It returns the current interest rate earned per epoch
  * @param market_data The MarketData struct of Market for Coin<T>
  * @param interest_rate_model_storage The shared storage object of the ipx::interest_rate_model 
  * @param market_key The key of the market
  * @return interest rate earned per epoch % for MarketData of Coin<T>
  */
  fun get_supply_rate_per_epoch_internal(
    market_data: &MarketData, 
    interest_rate_model_storage: &InterestRateModelStorage,
    market_key: String,
    ): u64 {
      // Other coins follow the start jump rate interest rate model       
      interest_rate_model::get_supply_rate_per_epoch(
          interest_rate_model_storage,
          market_key,
          market_data.balance_value,
          rebase::elastic(&market_data.loan_rebase),
          market_data.total_reserves,
          market_data.reserve_factor
        )
  }

  /**
  * @notice It allows the user to his shares in Market for Coin<T> as collateral to open loans 
  * @param account_storage The shared account storage object of ipx::whirpool 
  */
  public fun enter_market<T>(account_storage: &mut AccountStorage, ctx: &mut TxContext) {
    // Save the sender address in memory
    let sender = tx_context::sender(ctx);

    // Init the markets_in account if he never interacted with this market
    init_markets_in(account_storage, sender);

   // Get the user market_in account
   let user_markets_in = borrow_mut_user_markets_in(&mut account_storage.markets_in_table, sender);

   // Save the market key in memory
   let market_key = get_coin_info<T>();
   
   // Add the market_key to the account if it is not present
   if (!vector::contains(user_markets_in, &market_key)) { 
      vector::push_back(user_markets_in, market_key);
    };
  }

  /**
  * @notice It to remove his shares account as collateral.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  */
  public fun exit_market<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage, 
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    oracle_storage: &OracleStorage,
    ctx: &mut TxContext
  ) {
    let market_key = get_coin_info<T>();
    let sender = tx_context::sender(ctx);
    let account = borrow_account(account_storage, sender, market_key);

    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;

    // Sender cannot exist a market if he is currently borrowing from it
    assert!(account.principal == 0, ERROR_MARKET_EXIT_LOAN_OPEN);
   
   // Get user markets_in account
   let user_markets_in = borrow_mut_user_markets_in(&mut account_storage.markets_in_table, sender);
   
   // Verify if the user is indeed registered in this market and index in the vector
   let (is_present, index) = vector::index_of(user_markets_in, &market_key);
   
   // If he is in the market we remove.
   if (is_present) {
    let _ = vector::remove(user_markets_in, index);
   };

  // Sender must remain solvent after removing the account
  assert!(
     is_user_solvent(
      &mut whirpool_storage.market_data_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage, 
      ipx_per_epoch,
      total_allocation_points,
      market_key, 
      sender, 
      0, 
      0, 
      ctx
     ), 
    ERROR_USER_IS_INSOLVENT);
  }

  /**
  * @notice It returns a tuple containing the updated (collateral value, loan value) of a user for MarketData of Coin<T> 
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param user The address of the account we wish to check
  * @return (collateral value, loan value)
  */
  public fun get_account_balances<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage, 
    dinero_storage: &DineroStorage,
    user: address, 
    ctx: &mut TxContext
  ): (u64, u64) {
    let market_key = get_coin_info<T>();  
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;

    // Get the market data
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);
    // Get the user account
    let account = borrow_account(account_storage, user, market_key);
    
    get_account_balances_internal(
      market_data, 
      account, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    )
  }

  /**
  * @notice It returns a tuple containing the updated (collateral value, loan value) of a user for MarketData of Coin<T> 
  * @param market_data The MarketData struct
  * @param account The account struct of a user
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param market_key The key of the market in question
  * @param ipx_per_epoch The value of IPX to mint per epoch for the entire module
  * @param total_allocation_points It stores all allocation points assigned to all markets
  * @return (collateral value, loan value)
  */
  fun get_account_balances_internal(
    market_data: &mut MarketData,
    account: &Account,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    market_key: String, 
    ipx_per_epoch: u64,
    total_allocation_points: u64, 
    ctx: &mut TxContext
  ): (u64, u64) {
    if (tx_context::epoch(ctx) > market_data.accrued_epoch) 
      accrue_internal(
        market_data, 
        interest_rate_model_storage, 
        dinero_storage, 
        market_key, 
        ipx_per_epoch,
        total_allocation_points,
        ctx
      );

     (
      rebase::to_elastic(&market_data.collateral_rebase, account.shares, false), 
      rebase::to_elastic(&market_data.loan_rebase, account.principal, true)
     )
  }

  /**
  * @notice It updates the MarketData loan and rewards information
  * @param market_data The MarketData struct
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param market_key The key of the market in question
  * @param ipx_per_epoch The value of IPX to mint per epoch for the entire module
  * @param total_allocation_points It stores all allocation points assigned to all markets
  */
  fun accrue_internal(
    market_data: &mut MarketData, 
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    market_key: String,
    ipx_per_epoch: u64,
    total_allocation_points: u64, 
    ctx: &TxContext
  ) {
    let epochs_delta = tx_context::epoch(ctx) - market_data.accrued_epoch;

    // If no epochs have passed since the last update, there is nothing to do.
    if (epochs_delta == 0) return;

    // Calculate the interest rate % accumulated for all epochs since the last update
    let interest_rate = epochs_delta * get_borrow_rate_per_epoch_internal(market_data, interest_rate_model_storage, dinero_storage, market_key);


    // Calculate the total interest rate amount earned by the protocol
    let interest_rate_amount = fmul(interest_rate, rebase::elastic(&market_data.loan_rebase));
    // Calculate how much interest rate will be given to the reserves
    let reserve_interest_rate_amount = fmul(interest_rate_amount, market_data.reserve_factor);

    // Increase the total borrows by the interest rate amount
    rebase::increase_elastic(&mut market_data.loan_rebase, interest_rate_amount);
    // increase the total amount earned 
    rebase::increase_elastic(&mut market_data.collateral_rebase, interest_rate_amount - reserve_interest_rate_amount);

    // Update the accrued epoch
    market_data.accrued_epoch = tx_context::epoch(ctx);
    // Update the reserves
    market_data.total_reserves = market_data.total_reserves + reserve_interest_rate_amount;

    // Total IPX rewards accumulated for all passing epochs
    let rewards = (market_data.allocation_points as u256) * (epochs_delta as u256) * (ipx_per_epoch as u256) / (total_allocation_points as u256);

    // Split the rewards evenly between loans and collateral
    let collateral_rewards = rewards / 2; 
    let loan_rewards = rewards - collateral_rewards;

    // Get the total shares amount of the market
    let total_shares = rebase::base(&market_data.collateral_rebase);
    // Get the total borrow amount of the market
    let total_principal = rebase::base(&market_data.loan_rebase);

    // Update the total rewards per share.
    market_data.accrued_collateral_rewards_per_share = market_data.accrued_collateral_rewards_per_share + (collateral_rewards / (total_shares as u256));
    market_data.accrued_loan_rewards_per_share = market_data.accrued_loan_rewards_per_share + (loan_rewards / (total_principal as u256));
  } 

  /****************************************
    STORAGE GETTERS
  **********************************************/ 
  fun borrow_market_balance<T>(market_balance: &Bag, market_key: String): &MarketBalance<T> {
    bag::borrow(market_balance, market_key)
  }

  fun borrow_mut_market_balance<T>(market_balance: &mut Bag, market_key: String): &mut MarketBalance<T> {
    bag::borrow_mut(market_balance, market_key)
  }

  fun borrow_market_data(market_data: &Table<String, MarketData>, market_key: String): &MarketData {
    table::borrow(market_data, market_key)
  }

  fun borrow_mut_market_data(market_data: &mut Table<String, MarketData>, market_key: String): &mut MarketData {
    table::borrow_mut(market_data, market_key)
  }

  fun borrow_account(account_storage: &AccountStorage, user: address, market_key: String): &Account {
    table::borrow(table::borrow(&account_storage.accounts_table, market_key), user)
  }

  fun borrow_mut_account(account_storage: &mut AccountStorage, user: address, market_key: String): &mut Account {
    table::borrow_mut(table::borrow_mut(&mut account_storage.accounts_table, market_key), user)
  }

  fun borrow_user_markets_in(markets_in: &Table<address, vector<String>>, user: address): &vector<String> {
    table::borrow(markets_in, user)
  }

  fun borrow_mut_user_markets_in(markets_in: &mut Table<address, vector<String>>, user: address): &mut vector<String> {
    table::borrow_mut(markets_in, user)
  }

  fun account_exists(account_storage: &AccountStorage, user: address, market_key: String): bool {
    table::contains(table::borrow(&account_storage.accounts_table, market_key), user)
  }

  /**
  * @dev It registers an empty Account for a Market with key if it is not present
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param user The address of the user we wish to initiate his account
  */
  fun init_account(account_storage: &mut AccountStorage, user: address, key: String, ctx: &mut TxContext) {
    if (!account_exists(account_storage, user, key)) {
          table::add(
            table::borrow_mut(&mut account_storage.accounts_table, key),
            user,
            Account {
              id: object::new(ctx),
              principal: 0,
              shares: 0,
              collateral_rewards_paid: 0,
              loan_rewards_paid: 0
            }
        );
    };
  }

   /**
  * @dev It registers an empty markets_in for a user 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param user The address of the user we wish to initiate his markets_in vector
  */
  fun init_markets_in(account_storage: &mut AccountStorage, user: address) {
    if (!table::contains(&account_storage.markets_in_table, user)) {
      table::add(
       &mut account_storage.markets_in_table,
       user,
       vector::empty<String>()
      );
    };
  }

  /**
  * @dev A utility function to mint IPX.
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param value The value for Coin<IPX> to mint
  */
  fun mint_ipx(ipx_storage: &mut IPXStorage, value: u256, ctx: &mut TxContext): Coin<IPX> {
    // We can create a Coin<IPX> with 0 value without minting
    if (value == 0) { coin::zero<IPX>(ctx) } else { ipx::mint(ipx_storage, (value as u64), ctx) }
  }

  /**
  * @dev A utility function to get the price of a Coin<T> in USD with 9 decimals
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param The key of the Coin
  */
  fun get_price(oracle_storage: &OracleStorage, key: String): u64 {
    // DNR is always 1 USD regardless of prices anywhere else
    if (key == get_coin_info<DNR>()) return (one() as u64);

    // Fetch the price from the oracle
    let (price, decimals) = oracle::get_price(oracle_storage, key);

    // Normalize the price to have 9 decimals to work with fmul and fdiv
    (((price as u256) * one()) / (math::pow(10, decimals) as u256) as u64)
  }

  /**
  * @notice It allows the admin to update the interest rate per epoch for Coin<T>
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param base_rate_per_year The minimum rate per year
  * @param multiplier_rate_per_year The rate applied as the liquidity decreases
  * @param jump_multiplier_rate_per_year An amplified rate once the kink is passed to address low liquidity levels
  * @kink The threshold that decides when the liquidity is considered very low
  * @return (Coin<T>, Coin<IPX>)
  * Requirements: 
  * - Only the admin can call this function
  */
  entry public fun set_interest_rate_data<T>(
    _: &WhirpoolAdminCap,
    whirpool_storage: &mut WhirpoolStorage, 
    interest_rate_model_storage: &mut InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    base_rate_per_year: u64,
    multiplier_per_year: u64,
    jump_multiplier_per_year: u64,
    kink: u64,
    ctx: &mut TxContext
  ) {
    let market_key = get_coin_info<T>();
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;

    // Update the market information before updating its interest rate
    accrue_internal(
      borrow_mut_market_data(
        &mut whirpool_storage.market_data_table, 
        market_key
      ), 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points, 
      ctx
    );

    // Update the interest rate
    interest_rate_model::set_interest_rate_data<T>(
      interest_rate_model_storage,
      base_rate_per_year,
      multiplier_per_year,
      jump_multiplier_per_year,
      kink,
      ctx
    )
  } 

   /**
  * @notice It allows the admin to update the penalty fee and protocol percentage when a user is liquidated
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param penalty_fee The % fee a user pays when liquidated with 9 decimals
  * @param protocol_percentage The % of the penalty fee the protocol retains with 9 decimals
  */
  entry public fun update_liquidation<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage, 
    penalty_fee: u64,
    protocol_percentage: u64,
  ) {
    // Make sure the protocol can not seize the entire value of a position during liquidations
    assert!(TWENTY_FIVE_PER_CENT >= penalty_fee, ERROR_VALUE_TOO_HIGH);
    assert!(TWENTY_FIVE_PER_CENT >= protocol_percentage, ERROR_VALUE_TOO_HIGH);

    let liquidation = table::borrow_mut(&mut whirpool_storage.liquidation_table, get_coin_info<T>());
    liquidation.penalty_fee = penalty_fee;
    liquidation.protocol_percentage = protocol_percentage;
  }

  /**
  * @notice It allows the to add a new market for Coin<T>.
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param borrow_cap The maximum value that can be borrowed for this market 
  * @param collateral_cap The maximum amount of collateral that can be added to this market
  * @param ltv The loan to value ratio of this market 
  * @param allocation_points The % of rewards this market will get 
  * @param penalty_fee The % fee a user pays when liquidated with 9 decimals
  * @param protocol_percentage The % of the penalty fee the protocol retains with 9 decimals
  * @param decimals The decimal houses of Coin<T>
  */
  entry public fun create_market<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage, 
    borrow_cap: u64,
    collateral_cap: u64,
    ltv: u64,
    allocation_points: u64,
    penalty_fee: u64,
    protocol_percentage: u64,
    decimals: u8,
    ctx: &mut TxContext
    ) {
    // Make sure the protocol can not seize the entire value of a position during liquidations
    assert!(TWENTY_FIVE_PER_CENT >= penalty_fee, ERROR_VALUE_TOO_HIGH);
    assert!(TWENTY_FIVE_PER_CENT >= protocol_percentage, ERROR_VALUE_TOO_HIGH);

    let key = get_coin_info<T>();

    // We need this to loop through all the markets
    vector::push_back(&mut whirpool_storage.all_markets_keys, key);

    // Register the MarketData
    table::add(
      &mut whirpool_storage.market_data_table, 
      key,
      MarketData {
        id: object::new(ctx),
        total_reserves: 0,
        accrued_epoch: tx_context::epoch(ctx),
        borrow_cap,
        collateral_cap,
        balance_value: 0,
        is_paused: false,
        ltv,
        reserve_factor: INITIAL_RESERVE_FACTOR_MANTISSA,
        allocation_points,
        accrued_collateral_rewards_per_share: 0,
        accrued_loan_rewards_per_share: 0,
        collateral_rebase: rebase::new(),
        loan_rebase: rebase::new(),
        decimals_factor: math::pow(10, decimals)
    });

    // Register the liquidation data
    table::add(
      &mut whirpool_storage.liquidation_table,
      key,
      Liquidation {
        id: object::new(ctx),
        penalty_fee,
        protocol_percentage
      }
    );

    // Add the market tokens
    bag::add(
      &mut whirpool_storage.market_balance_bag, 
      key,
      MarketBalance {
        id: object::new(ctx),
        balance: balance::zero<T>()
      });  

    // Add bag to store address -> account
    table::add(
      &mut account_storage.accounts_table,
      key,
      table::new(ctx)
    );  

    // Update the total allocation points
    whirpool_storage.total_allocation_points = whirpool_storage.total_allocation_points + allocation_points;
  }

  /**
  * @notice It allows the admin to pause the market
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  */
  entry public fun pause_market<T>(_: &WhirpoolAdminCap, whirpool_storage: &mut WhirpoolStorage) {
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, get_coin_info<T>());
    market_data.is_paused = true;
  }

  /**
  * @notice It allows the admin to unpause the market
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  */
  entry public fun unpause_market<T>(_: &WhirpoolAdminCap, whirpool_storage: &mut WhirpoolStorage) {
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, get_coin_info<T>());
    market_data.is_paused = false;
  }

  /**
  * @notice It allows the admin to update the borrow cap for Market T
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param borrow_cap The new borrow cap for Market T
  */
  entry public fun set_borrow_cap<T>(
    _: &WhirpoolAdminCap, 
     whirpool_storage: &mut WhirpoolStorage,
    borrow_cap: u64
    ) {
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, get_coin_info<T>());
     
     market_data.borrow_cap = borrow_cap;
  }

  /**
  * @notice It allows the admin to update the reserve factor for Market T
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param new_reserve_factor The new reserve factor for market
  */
  entry public fun update_reserve_factor<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    new_reserve_factor: u64,
    ctx: &mut TxContext
  ) {
    assert!(TWENTY_FIVE_PER_CENT >= new_reserve_factor, ERROR_VALUE_TOO_HIGH);
    let market_key = get_coin_info<T>();
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // We need to update the loan information before updating the reserve factor
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    market_data.reserve_factor = new_reserve_factor;
  }

  /**
  * @notice It allows the admin to withdraw the reserves for Market T
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param withdraw_value The value of reserves to withdraw
  */
  entry public fun withdraw_reserves<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    withdraw_value: u64,
    ctx: &mut TxContext
  ) {
    let market_key = get_coin_info<T>();
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Need to update the loan information before withdrawing the reserves
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // There must be enough reserves and cash in the market
    assert!(withdraw_value >= market_data.balance_value, ERROR_NOT_ENOUGH_CASH_TO_WITHDRAW);
    assert!(withdraw_value >= market_data.total_reserves, ERROR_NOT_ENOUGH_RESERVES);

    // Send tokens to the admin
    transfer::transfer(
      coin::take<T>(&mut borrow_mut_market_balance<T>(&mut whirpool_storage.market_balance_bag, market_key).balance, withdraw_value, ctx),
      tx_context::sender(ctx)
    );
  }


  /**
  * @notice It allows the admin to update the ltv of a market
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param new_ltv The new ltv for the market
  */
  entry public fun update_ltv<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    new_ltv: u64,
    ctx: &mut TxContext
  ) {
    let market_key = get_coin_info<T>();
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Update the loans before updating the ltv
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    market_data.ltv = new_ltv;
  }

  /**
  * @notice It allows the admin to update the dinero interest rate per epoch
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param new_interest_rate_per_epoch The new Dinero interest rate
  */
  entry public fun update_dnr_interest_rate_per_epoch(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &mut DineroStorage,
    new_interest_rate_per_epoch: u64,
    ctx: &mut TxContext
  ) {
    // Get DNR key
    let market_key = get_coin_info<DNR>();
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Update the Dinero market before updating the interest rate
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    dnr::update_interest_rate_per_epoch(dinero_storage, new_interest_rate_per_epoch)
  }

  /**
  * @notice It allows the admin to update the allocation points for Market T
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param new_allocation_points The new allocation points for Market T
  */
  entry public fun update_the_allocation_points<T>(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &mut DineroStorage,
    new_allocation_points: u64,
    ctx: &mut TxContext
  ) {
    let market_key = get_coin_info<T>();
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // We need to update the rewards
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    let old_allocation_points = market_data.allocation_points;
    // Update the market allocation points
    market_data.allocation_points = new_allocation_points;
    // Update the total allocation points
    whirpool_storage.total_allocation_points = whirpool_storage.total_allocation_points + new_allocation_points - old_allocation_points;
  }

  /**
  * @notice It allows the admin to update the ipx per epoch
  * @param _ The WhirpoolAdminCap
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param new_ipx_per_epoch The value of Coin<IPX> that this module will mint per epoch
  */
  entry public fun update_ipx_per_epoch(
    _: &WhirpoolAdminCap, 
    whirpool_storage: &mut WhirpoolStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &mut DineroStorage,
    new_ipx_per_epoch: u64,
    ctx: &mut TxContext
  ) {
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;

    let copy_vector = vector::empty<String>();
    let num_of_markets = vector::length(&whirpool_storage.all_markets_keys);
    let index = 0;

    // We need to update all market rewards before updating the ipx per epoch
    while (index < num_of_markets) {
      // We empty out this vector
      let key = vector::pop_back(&mut whirpool_storage.all_markets_keys);
      // Put the key back in the copy
      vector::push_back(&mut copy_vector, key);

      accrue_internal(
        borrow_mut_market_data(&mut whirpool_storage.market_data_table, key), 
        interest_rate_model_storage, 
        dinero_storage, 
        key, 
        ipx_per_epoch,
        total_allocation_points,
        ctx
      );


      index = index + 1;
    };

    // Update the ipx per epoch
    whirpool_storage.ipx_per_epoch = new_ipx_per_epoch;
    // Restore the all markets keys
    whirpool_storage.all_markets_keys = copy_vector;
  }

  /**
  * @notice It allows the admin to transfer the rights to a new admin
  * @param whirpool_admin_cap The WhirpoolAdminCap
  * @param new_admin The address f the new admin
  * Requirements: 
  * - The new_admin cannot be the address zero.
  */
  entry fun transfer_admin_cap(
    whirpool_admin_cap: WhirpoolAdminCap, 
    new_admin: address
  ) {
    assert!(new_admin != @0x0, ERROR_NO_ADDRESS_ZERO);
    transfer::transfer(whirpool_admin_cap, new_admin);
  }

  // DNR operations


  /**
  * @notice It allows a user to borrow Coin<DNR>.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param borrow_value The value of Coin<T> the user wishes to borrow
  * @return (Coin<DNR>, Coin<IPX>)
  * Requirements: 
  * - Market is not paused 
  * - User is solvent after borrowing Coin<DNR> collateral
  * - Market borrow cap has not been reached
  */
  public fun borrow_dnr(
    whirpool_storage: &mut WhirpoolStorage,
    account_storage: &mut AccountStorage, 
    interest_rate_model_storage: &mut InterestRateModelStorage,
    ipx_storage: &mut IPXStorage,
    dinero_storage: &mut DineroStorage,
    oracle_storage: &OracleStorage,
    borrow_value: u64,
    ctx: &mut TxContext
  ): (Coin<DNR>, Coin<IPX>) {
    // Get the type name of the Coin<DNR> of this market.
    let market_key = get_coin_info<DNR>();

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // Save the sender address in memory
    let sender = tx_context::sender(ctx);

    // Init the acount if the user never borrowed or deposited in this market
    init_account(account_storage, sender, market_key, ctx);

    // Register market in vector if the user never entered any market before
    init_markets_in(account_storage, sender);

    // Get the user account
    let account = borrow_mut_account(account_storage, sender, market_key);

    let pending_rewards = 0;
    // If the sender has a loan already, we need to calculate his rewards before this loan.
    if (account.principal > 0) 
      // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
      pending_rewards = (
        (account.principal as u256) * 
        market_data.accrued_loan_rewards_per_share / 
        (market_data.decimals_factor as u256)) - 
        account.loan_rewards_paid;

    // Update the loan rebase with the new loan
    let borrow_principal = rebase::add_elastic(&mut market_data.loan_rebase, borrow_value, true);

    // Update the principal owed by the sender
    account.principal = account.principal + borrow_principal; 
    // Consider all rewards paid
    account.loan_rewards_paid = (account.principal as u256) * market_data.accrued_loan_rewards_per_share / (market_data.decimals_factor as u256);

    // Check should be the last action after all mutations
    assert!(borrow_allowed(
      &mut whirpool_storage.market_data_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage,
      ipx_per_epoch,
      total_allocation_points, 
      market_key, 
      sender, 
      borrow_value, 
      ctx), 
    ERROR_BORROW_NOT_ALLOWED);

    (
      dnr::mint(dinero_storage, borrow_value, ctx), 
      mint_ipx(ipx_storage, pending_rewards, ctx)
    )
  }

  /**
  * @notice It allows a user repay his principal of Coin<DNR>.  
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param asset The Coin<DNR> he is repaying. 
  * @param principal_to_repay The principal he wishes to repay
  * @return Coin<IPX> rewards
  * Requirements: 
  * - Market is not paused 
  */
  public fun repay_dnr(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &mut DineroStorage,
    asset: Coin<DNR>,
    principal_to_repay: u64,
    ctx: &mut TxContext 
  ): Coin<IPX> {
  // Get the type name of the Coin<DNR> of this market.
    let market_key = get_coin_info<DNR>();

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );
    
    // Save the sender in memory
    let sender = tx_context::sender(ctx);

    // Get the sender account
    let account = borrow_mut_account(account_storage, sender, market_key);

    // Calculate the sender rewards before repayment
    // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
    let pending_rewards = (
        (account.principal as u256) * 
        market_data.accrued_loan_rewards_per_share / 
        (market_data.decimals_factor as u256)) - 
        account.loan_rewards_paid;

    // Save the value of Coin<T> in memory
    let asset_value = coin::value(&asset);

    // Convert asset_value to principal
    let asset_principal = rebase::to_base(&market_data.loan_rebase, asset_value, false);

    // Ensure that the user is not overpaying his loan. This is important because interest rate keeps accrueing every second.
    // Users will usually send more Coin<T> then needed
    let safe_asset_principal = if (asset_principal > account.principal) { math::min(principal_to_repay, account.principal )} else { math::min(asset_principal, principal_to_repay) };

    // Convert the safe principal to Coin<T> value so we can send any extra back to the user
    let repay_amount = rebase::to_elastic(&market_data.loan_rebase, safe_asset_principal, true);

    // If the sender send more Coin<T> then necessary, we return the extra to him
    if (asset_value > repay_amount) pay::split_and_transfer(&mut asset, asset_value - repay_amount, sender, ctx);
    // Remove the principal repaid from the user account
    account.principal = account.principal - safe_asset_principal;
    // Consider all rewards paid
    account.loan_rewards_paid = (account.principal as u256) * market_data.accrued_loan_rewards_per_share / (market_data.decimals_factor as u256);
    // Burn the DNR
    dnr::burn(dinero_storage, asset);

    assert!(repay_allowed(market_data), ERROR_REPAY_NOT_ALLOWED);
    mint_ipx(ipx_storage, pending_rewards, ctx)
  }

   /**
  * @notice It allows the sender to get his collateral and loan Coin<IPX> rewards for Market T
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @return Coin<IPX> It will mint IPX rewards to the user.
  */
  public fun get_rewards<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &mut DineroStorage,
    ctx: &mut TxContext 
  ): Coin<IPX> {
    // Call the view functions to get the values
    let (collateral_rewards, loan_rewards) = get_pending_rewards<T>(
      whirpool_storage, 
      account_storage, 
      interest_rate_model_storage, 
      dinero_storage, 
      tx_context::sender(ctx),
      ctx
    ); 

    // Mint the IPX
    mint_ipx(ipx_storage, collateral_rewards + loan_rewards, ctx)
  }

  /**
  * @notice It allows the sender to get his collateral and loan Coin<IPX> rewards for ALL markets
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @return Coin<IPX> It will mint IPX rewards to the user.
  */
  fun get_all_rewards(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    ipx_storage: &mut IPXStorage, 
    dinero_storage: &mut DineroStorage,
    ctx: &mut TxContext 
  ): Coin<IPX> {
    let all_market_keys = whirpool_storage.all_markets_keys;
    // We will empty all market keys
    let copy_all_market_keys = vector::empty<String>();
    // We need to know how many markets exist to loop through them
    let num_of_markets = vector::length(&all_market_keys);

    let index = 0;
    let all_rewards = 0;
    let sender = tx_context::sender(ctx);

    while(index < num_of_markets) {
      let key = vector::pop_back(&mut all_market_keys);
      vector::push_back(&mut copy_all_market_keys, key);

      let (collateral_rewards, loan_rewards) = get_pending_rewards_internal(
        whirpool_storage,
        account_storage,
        interest_rate_model_storage, 
        dinero_storage,
        key,
        sender,
        ctx
      );  

      // Add the rewards
      all_rewards = all_rewards + collateral_rewards + loan_rewards;
      // Inc index
      index = index + 1;
    };

    // Restore all market keys
    whirpool_storage.all_markets_keys = copy_all_market_keys;

    // mint Coin<IPX>
    mint_ipx(ipx_storage, all_rewards, ctx)
  }


   /**
  * @notice It allows the caller to get the value of a user collateral and loan rewards
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param user The address of the account
  * @return Coin<IPX> It will mint IPX rewards to the user.
  */
  public fun get_pending_rewards<T>(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &mut DineroStorage,
    user: address,
    ctx: &mut TxContext 
  ): (u256, u256) {
        // Get the type name of the Coin<T> of this market.
    let market_key = get_coin_info<T>();

    get_pending_rewards_internal(
      whirpool_storage,
      account_storage,
      interest_rate_model_storage, 
      dinero_storage,
      market_key,
      user,
      ctx
    )  
  }

 /**
  * @notice It allows a user to liquidate a borrower for a reward 
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param asset The Coin<L> he is repaying. 
  * @param principal_to_repay The principal he wishes to repay
  * Requirements: 
  * - borrower is insolvent
  */
  public fun liquidate<C, L>(
    whirpool_storage: &mut WhirpoolStorage,
    account_storage: &mut AccountStorage, 
    interest_rate_model_storage: &mut InterestRateModelStorage,
    ipx_storage: &mut IPXStorage,
    dinero_storage: &mut DineroStorage,
    oracle_storage: &OracleStorage,
    asset: Coin<L>,
    borrower: address,
    ctx: &mut TxContext
  ) {
    // Get keys for collateral, loan and dnr market
    let collateral_market_key = get_coin_info<C>();
    let loan_market_key = get_coin_info<L>();
    let dnr_market_key = get_coin_info<DNR>();
    let liquidator_address = tx_context::sender(ctx);
    
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;

    // Get liquidation info for collateral market
    let liquidation = table::borrow(&whirpool_storage.liquidation_table, collateral_market_key);

    let penalty_fee = liquidation.penalty_fee;
    let protocol_fee = liquidation.protocol_percentage;

    // User cannot liquidate himself
    assert!(liquidator_address != borrower, ERROR_LIQUIDATOR_IS_BORROWER);
    // DNR cannot be used as collateral
    // DNR liquidation has its own function
    assert!(collateral_market_key != dnr_market_key, ERROR_DNR_OPERATION_NOT_ALLOWED);
    assert!(loan_market_key != dnr_market_key, ERROR_DNR_OPERATION_NOT_ALLOWED);

    // Update the collateral market
    accrue_internal(
      borrow_mut_market_data(&mut whirpool_storage.market_data_table, collateral_market_key), 
      interest_rate_model_storage, 
      dinero_storage, 
      collateral_market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );
    // Update the loan market
    accrue_internal(
      borrow_mut_market_data(&mut whirpool_storage.market_data_table, loan_market_key), 
      interest_rate_model_storage, 
      dinero_storage, 
      loan_market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // Accounts must exist or there is no point o proceed.
    assert!(account_exists(account_storage, borrower, collateral_market_key), ERROR_ACCOUNT_COLLATERAL_DOES_EXIST);
    assert!(account_exists(account_storage, borrower, loan_market_key), ERROR_ACCOUNT_LOAN_DOES_EXIST);

    // If the liquidator does not have an account in the collateral market, we make one. 
    // So he can accept the collateral
    init_account(account_storage, liquidator_address, collateral_market_key, ctx);
    
    // User must be insolvent
    assert!(!is_user_solvent(
      &mut whirpool_storage.market_data_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage, 
      ipx_per_epoch,
      total_allocation_points,
      collateral_market_key, 
      borrower, 
      0, 
      0, 
      ctx), 
    ERROR_USER_IS_SOLVENT);

    // Get the borrower loan account information
    let borrower_loan_account = borrow_mut_account(account_storage, borrower, loan_market_key);
    // Convert the principal to a nominal amount
    let borrower_loan_amount = rebase::to_elastic(
      &borrow_market_data(&whirpool_storage.market_data_table, loan_market_key).loan_rebase, 
      borrower_loan_account.principal, 
      true
      );

    // Get the value the liquidator wishes to repay
    let asset_value = coin::value(&asset);

    // The liquidator cannot liquidate more than the total loan
    let repay_max_amount = if (asset_value > borrower_loan_amount) { borrower_loan_amount } else { asset_value };

    // Liquidator must liquidate a value greater than 0, or no point to proceed
    assert!(repay_max_amount != 0, ERROR_ZERO_LIQUIDATION_AMOUNT);

    // Return to the liquioator any extra value
    if (asset_value > repay_max_amount) pay::split_and_transfer(&mut asset, asset_value - repay_max_amount, liquidator_address, ctx);

    // Deposit the coins in the market
    balance::join(&mut borrow_mut_market_balance<L>(&mut whirpool_storage.market_balance_bag, loan_market_key).balance, coin::into_balance(asset));
    let loan_market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, loan_market_key);
    // Update the cash in the loan market
    loan_market_data.balance_value = loan_market_data.balance_value + repay_max_amount;

    // Convert the repay amount to principal
    let base_repay = rebase::to_base(&loan_market_data.loan_rebase, repay_max_amount, true);

    // We need to send the user his loan rewards before the liquidation
    let pending_rewards =  (
        (borrower_loan_account.principal as u256) * 
        loan_market_data.accrued_loan_rewards_per_share / 
        (loan_market_data.decimals_factor as u256)) - 
        borrower_loan_account.loan_rewards_paid;
    
    // Consider the loan repaid
    // Update the user principal info
    borrower_loan_account.principal = borrower_loan_account.principal - math::min(base_repay, borrower_loan_account.principal);
    // Consider his loan rewards paid.
    borrower_loan_account.loan_rewards_paid = (borrower_loan_account.principal as u256) * loan_market_data.accrued_loan_rewards_per_share / (loan_market_data.decimals_factor as u256);

    // Update the market loan info
    rebase::sub_base(&mut loan_market_data.loan_rebase, base_repay, false);

    let collateral_price_normalized = get_price(oracle_storage, collateral_market_key);
    let loan_price_normalized = get_price(oracle_storage, loan_market_key);

    let collateral_seize_amount = fdiv(fmul(loan_price_normalized, repay_max_amount), collateral_price_normalized); 
    let penalty_fee_amount = fmul(collateral_seize_amount, penalty_fee);
    let collateral_seize_amount_with_fee = collateral_seize_amount + penalty_fee_amount;

    // Calculate how much collateral to assign to the protocol and liquidator
    let protocol_amount = fmul(penalty_fee_amount, protocol_fee);
    let liquidator_amount = collateral_seize_amount_with_fee - protocol_amount;

    // Get the borrower collateral account
    let collateral_market_data = borrow_market_data(&mut whirpool_storage.market_data_table, collateral_market_key);
    let borrower_collateral_account = borrow_mut_account(account_storage, borrower, collateral_market_key);

    // We need to add the collateral rewards to the user.
    // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
    pending_rewards = pending_rewards + ((borrower_collateral_account.shares as u256) * 
          collateral_market_data.accrued_collateral_rewards_per_share / 
          (collateral_market_data.decimals_factor as u256)) - 
          borrower_collateral_account.collateral_rewards_paid;

    // Remove the shares from the borrower
    borrower_collateral_account.shares = borrower_collateral_account.shares - math::min(rebase::to_base(&collateral_market_data.collateral_rebase, collateral_seize_amount_with_fee, true), borrower_collateral_account.shares);

    // Consider all rewards earned by the sender paid
    borrower_collateral_account.collateral_rewards_paid = (borrower_collateral_account.shares as u256) * collateral_market_data.accrued_collateral_rewards_per_share / (collateral_market_data.decimals_factor as u256);

    // Give the shares to the liquidator
    let liquidator_collateral_account = borrow_mut_account(account_storage, liquidator_address, collateral_market_key);

    liquidator_collateral_account.shares = liquidator_collateral_account.shares + rebase::to_base(&collateral_market_data.collateral_rebase, liquidator_amount, false);
    // Consider the liquidator rewards paid
    liquidator_collateral_account.collateral_rewards_paid = (liquidator_collateral_account.shares as u256) * collateral_market_data.accrued_collateral_rewards_per_share / (collateral_market_data.decimals_factor as u256);

    // Give reserves to the protocol
    let collateral_market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, collateral_market_key);
    collateral_market_data.total_reserves = collateral_market_data.total_reserves + protocol_amount;

    // Send the rewards to the borrower
    transfer::transfer(mint_ipx(ipx_storage, pending_rewards, ctx), borrower);
  }

  /**
  * @notice It allows a user to liquidate a borrower for a reward 
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param asset The Coin<DNR> he is repaying. 
  * @param principal_to_repay The principal he wishes to repay
  * Requirements: 
  * - borrower is insolvent
  */
  public fun liquidate_dnr<C>(
   whirpool_storage: &mut WhirpoolStorage,
    account_storage: &mut AccountStorage, 
    interest_rate_model_storage: &mut InterestRateModelStorage,
    ipx_storage: &mut IPXStorage,
    dinero_storage: &mut DineroStorage,
    oracle_storage: &OracleStorage,
    asset: Coin<DNR>,
    borrower: address,
    ctx: &mut TxContext
  ) {
    // Get keys for collateral, loan and dnr market
    let collateral_market_key = get_coin_info<C>();
    let dnr_market_key = get_coin_info<DNR>();
    let liquidator_address = tx_context::sender(ctx);
    
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;

    // Get liquidation info for collateral market
    let liquidation = table::borrow(&whirpool_storage.liquidation_table, collateral_market_key);

    let penalty_fee = liquidation.penalty_fee;
    let protocol_fee = liquidation.protocol_percentage;

    // User cannot liquidate himself
    assert!(liquidator_address != borrower, ERROR_LIQUIDATOR_IS_BORROWER);
    // DNR cannot be used as collateral
    assert!(collateral_market_key != dnr_market_key, ERROR_DNR_OPERATION_NOT_ALLOWED);

    // Update the collateral market
    accrue_internal(
      borrow_mut_market_data(&mut whirpool_storage.market_data_table, collateral_market_key), 
      interest_rate_model_storage, 
      dinero_storage, 
      collateral_market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );
    // Update the loan market
    accrue_internal(
      borrow_mut_market_data(&mut whirpool_storage.market_data_table, dnr_market_key), 
      interest_rate_model_storage, 
      dinero_storage, 
      dnr_market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

    // Accounts must exist or there is no point o proceed.
    assert!(account_exists(account_storage, borrower, collateral_market_key), ERROR_ACCOUNT_COLLATERAL_DOES_EXIST);
    assert!(account_exists(account_storage, borrower, dnr_market_key), ERROR_ACCOUNT_LOAN_DOES_EXIST);

    // If the liquidator does not have an account in the collateral market, we make one. 
    // So he can accept the collateral
    init_account(account_storage, liquidator_address, collateral_market_key, ctx);
    
    // User must be insolvent
    assert!(!is_user_solvent(
      &mut whirpool_storage.market_data_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage, 
      ipx_per_epoch,
      total_allocation_points,
      collateral_market_key, 
      borrower, 
      0, 
      0, 
      ctx), 
    ERROR_USER_IS_SOLVENT);

    // Get the borrower loan account information
    let borrower_loan_account = borrow_mut_account(account_storage, borrower, dnr_market_key);
    // Convert the principal to a nominal amount
    let borrower_loan_amount = rebase::to_elastic(
      &borrow_market_data(&whirpool_storage.market_data_table, dnr_market_key).loan_rebase, 
      borrower_loan_account.principal, 
      true
      );

    // Get the value the liquidator wishes to repay
    let asset_value = coin::value(&asset);

    // The liquidator cannot liquidate more than the total loan
    let repay_max_amount = if (asset_value > borrower_loan_amount) { borrower_loan_amount } else { asset_value };

    // Liquidator must liquidate a value greater than 0, or no point to proceed
    assert!(repay_max_amount != 0, ERROR_ZERO_LIQUIDATION_AMOUNT);

    // Return to the liquioator any extra value
    if (asset_value > repay_max_amount) pay::split_and_transfer(&mut asset, asset_value - repay_max_amount, liquidator_address, ctx);

    // Burn the DNR
    dnr::burn(dinero_storage, asset);


    let loan_market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, dnr_market_key);

    // Convert the repay amount to principal
    let base_repay = rebase::to_base(&loan_market_data.loan_rebase, repay_max_amount, true);

    // We need to send the user his loan rewards before the liquidation
    let pending_rewards = (
        (borrower_loan_account.principal as u256) * 
        loan_market_data.accrued_loan_rewards_per_share / 
        (loan_market_data.decimals_factor as u256)) - 
        borrower_loan_account.loan_rewards_paid;
    
    // Consider the loan repaid
    // Update the user principal info
    borrower_loan_account.principal = borrower_loan_account.principal - math::min(base_repay, borrower_loan_account.principal);
    // Consider his loan rewards paid.
    borrower_loan_account.loan_rewards_paid = (borrower_loan_account.principal as u256) * loan_market_data.accrued_loan_rewards_per_share / (loan_market_data.decimals_factor as u256);

    // Update the market loan info
    rebase::sub_base(&mut loan_market_data.loan_rebase, base_repay, false);

    let collateral_price_normalized = get_price(oracle_storage, collateral_market_key);

    let collateral_seize_amount = fdiv(repay_max_amount, collateral_price_normalized); 
    let penalty_fee_amount = fmul(collateral_seize_amount, penalty_fee);
    let collateral_seize_amount_with_fee = collateral_seize_amount + penalty_fee_amount;

    // Calculate how much collateral to assign to the protocol and liquidator
    let protocol_amount = fmul(penalty_fee_amount, protocol_fee);
    let liquidator_amount = collateral_seize_amount_with_fee - protocol_amount;

    

    // Get the borrower collateral account
    let collateral_market_data = borrow_market_data(&mut whirpool_storage.market_data_table, collateral_market_key);
    let borrower_collateral_account = borrow_mut_account(account_storage, borrower, collateral_market_key);

    // We need to add the collateral rewards to the user.
    // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
    pending_rewards = pending_rewards + ((borrower_collateral_account.shares as u256) * 
          collateral_market_data.accrued_collateral_rewards_per_share / 
          (collateral_market_data.decimals_factor as u256)) - 
          borrower_collateral_account.collateral_rewards_paid;

    // Remove the shares from the borrower
    borrower_collateral_account.shares = borrower_collateral_account.shares - math::min(rebase::to_base(&collateral_market_data.collateral_rebase, collateral_seize_amount_with_fee, true), borrower_collateral_account.shares);

    // Consider all rewards earned by the sender paid
    borrower_collateral_account.collateral_rewards_paid = (borrower_collateral_account.shares as u256) * collateral_market_data.accrued_collateral_rewards_per_share / (collateral_market_data.decimals_factor as u256);

    // Give the shares to the liquidator
    let liquidator_collateral_account = borrow_mut_account(account_storage, liquidator_address, collateral_market_key);

    liquidator_collateral_account.shares = liquidator_collateral_account.shares + rebase::to_base(&collateral_market_data.collateral_rebase, liquidator_amount, false);
    // Consider the liquidator rewards paid
    liquidator_collateral_account.collateral_rewards_paid = (liquidator_collateral_account.shares as u256) * collateral_market_data.accrued_collateral_rewards_per_share / (collateral_market_data.decimals_factor as u256);

    // Give reserves to the protocol
    let collateral_market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, collateral_market_key);
    collateral_market_data.total_reserves = collateral_market_data.total_reserves + protocol_amount;

    // Send the rewards to the borrower
    transfer::transfer(mint_ipx(ipx_storage, pending_rewards, ctx), borrower);
  }

  // Controller

   /**
  * @notice Defensive hook to make sure the market is not paused and the collateral cap has not been reached
  * @param market_data A Market
  * @return bool true if the user is allowed to deposit
  */
  fun deposit_allowed(market_data: &MarketData): bool {
    assert!(!market_data.is_paused, ERROR_MARKET_IS_PAUSED);
    assert!(market_data.collateral_cap >= rebase::elastic(&market_data.collateral_rebase), ERROR_MAX_COLLATERAL_REACHED);
    true
  }

   /**
  * @notice Defensive hook to make sure that the user can withdraw
  * @param market_table The table that holds the MarketData structs
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param ipx_per_epoch The value of Coin<IPX> this module can mint per epoch
  * @param total_allocation_points The total rewards points in the module
  * @param market_key The key of the market the user is trying to withdraw
  * @param user The address of the user that is trying to withdraw
  * @param coin_value The value he is withdrawing from the market
  * @return bool true if the user can withdraw
  * Requirements
  * - The user must be solvent after withdrawing.
  */
  fun withdraw_allowed(
    market_table: &mut Table<String, MarketData>, 
    account_storage: &mut AccountStorage, 
    oracle_storage: &OracleStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    ipx_per_epoch: u64,
    total_allocation_points: u64, 
    market_key: String,
    user: address, 
    coin_value: u64,
    ctx: &mut TxContext
  ): bool {
    // Market is not paused
    assert!(!borrow_market_data(market_table, market_key).is_paused, ERROR_MARKET_IS_PAUSED);

    // If the user has no loans, he can withdraw
    if (!table::contains(&account_storage.markets_in_table, user)) return true;

    // Check if the user is solvent
    is_user_solvent(
      market_table, 
      account_storage, 
      oracle_storage, 
      interest_rate_model_storage, 
      dinero_storage,
      ipx_per_epoch,
      total_allocation_points, 
      market_key, 
      user, 
      coin_value, 
      0, 
      ctx
    )
  }

  /**
  * @notice Defensive hook to make sure that the user can borrow
  * @param market_table The table that holds the MarketData structs
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param ipx_per_epoch The value of Coin<IPX> this module can mint per epoch
  * @param total_allocation_points The total rewards points in the module
  * @param market_key The key of the market the user is trying to borrow from
  * @param user The address of the user that is trying to borrow
  * @param coin_value The value the user is borrowing
  * @return bool true if the user can borrow
  * Requirements
  * - The user must be solvent after withdrawing.
  */
  fun borrow_allowed(
    market_table: &mut Table<String, MarketData>, 
    account_storage: &mut AccountStorage, 
    oracle_storage: &OracleStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    ipx_per_epoch: u64,
    total_allocation_points: u64, 
    market_key: String,
    user: address, 
    coin_value: u64,
    ctx: &mut TxContext
    ): bool {
      let current_market_data = borrow_market_data(market_table, market_key);

      assert!(!current_market_data.is_paused, ERROR_MARKET_IS_PAUSED);

      let user_markets_in = borrow_mut_user_markets_in(&mut account_storage.markets_in_table, user);

      // We need to add this market to the markets_in if he is getting a loan and is not registered
      if (!vector::contains(user_markets_in, &market_key)) { 
        vector::push_back(user_markets_in, market_key);
      };

      // Ensure that the borrow cap is not met
      assert!(current_market_data.borrow_cap >= rebase::elastic(&current_market_data.collateral_rebase), ERROR_BORROW_CAP_LIMIT_REACHED);

      // User must remain solvent
      is_user_solvent(
        market_table, 
        account_storage, 
        oracle_storage, 
        interest_rate_model_storage, 
        dinero_storage, 
        ipx_per_epoch,
        total_allocation_points,
        market_key, 
        user, 
        0, 
        coin_value, 
        ctx
      )
  }


  /**
  * @notice Defensive hook to make sure that the user can repay
  * @param market_table The table that holds the MarketData structs
  */
  fun repay_allowed(market_data: &MarketData): bool {
    // Ensure that the market is not paused
    assert!(!market_data.is_paused, ERROR_MARKET_IS_PAUSED);
    true
  }

     /**
  * @notice It allows the caller to get the value of a user collateral and loan rewards
  * @param whirpool_storage The shared storage object of ipx::whirpool 
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param ipx_storage The shared object of the module ipx::ipx 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param user The address of the account
  * @return Coin<IPX> It will mint IPX rewards to the user.
  */
  fun get_pending_rewards_internal(
    whirpool_storage: &mut WhirpoolStorage, 
    account_storage: &mut AccountStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &mut DineroStorage,
    market_key: String,
    user: address,
    ctx: &mut TxContext 
  ): (u256, u256) {

    // Reward information in memory
    let ipx_per_epoch = whirpool_storage.ipx_per_epoch;
    let total_allocation_points = whirpool_storage.total_allocation_points;
      
    // Get market core information
    let market_data = borrow_mut_market_data(&mut whirpool_storage.market_data_table, market_key);

    // Update the market rewards & loans before any mutations
    accrue_internal(
      market_data, 
      interest_rate_model_storage, 
      dinero_storage, 
      market_key, 
      ipx_per_epoch,
      total_allocation_points,
      ctx
    );

      // Get the caller Account to update
      let account = borrow_mut_account(account_storage, user, market_key);

      let pending_collateral_rewards = 0;
      let pending_loan_rewards = 0;

      // If the sender has shares already, we need to calculate his rewards before this deposit.
      if (account.shares != 0) 
        // Math: we need to remove the decimals of shares during fixed point multiplication to maintain IPX decimal houses
        pending_collateral_rewards = (
          (account.shares as u256) * 
          market_data.accrued_collateral_rewards_per_share / 
          (market_data.decimals_factor as u256)) - 
          account.collateral_rewards_paid;

       // If the user has a loan in this market, he is entitled to rewards
       if(account.principal != 0) 
        pending_loan_rewards = (
          (account.principal as u256) * 
          market_data.accrued_loan_rewards_per_share / 
          (market_data.decimals_factor as u256)) - 
          account.loan_rewards_paid;

      (pending_collateral_rewards, pending_loan_rewards)      
  }

  /**
  * @notice It checks if a user is solvent after withdrawing and borrowing
  * @param market_table The table that holds the MarketData structs
  * @param account_storage The shared account storage object of ipx::whirpool 
  * @param oracle_storage The shared object of the module ipx::oracle 
  * @param interest_rate_model_storage The shared object of the module ipx::interest_rate_model 
  * @param dinero_storage The shared ofbject of the module ipx::dnr 
  * @param ipx_per_epoch The value of Coin<IPX> this module can mint per epoch
  * @param total_allocation_points The total rewards points in the module
  * @param modified_market_key The key of the market the user is trying to borrow or withdraw from
  * @param user The address of the user that is trying to borrow or withdraw
  * @param withdraw_coin_value The value that the user is trying to withdraw
  * @param borrow_coin_value The value that user is trying to borrow
  * @return bool true if the user can borrow
  * Requirements
  * - The user must be solvent after withdrawing.
  */
  fun is_user_solvent(
    market_table: &mut Table<String, MarketData>, 
    account_storage: &mut AccountStorage, 
    oracle_storage: &OracleStorage,
    interest_rate_model_storage: &InterestRateModelStorage,
    dinero_storage: &DineroStorage,
    ipx_per_epoch: u64,
    total_allocation_points: u64, 
    modified_market_key: String,
    user: address,
    withdraw_coin_value: u64,
    borrow_coin_value: u64,
    ctx: &mut TxContext
  ): bool {
    // Get the list of the markets the user is in. 
    // No point to calculate the data for markets the user is not in.
    let user_markets_in = borrow_mut_user_markets_in(&mut account_storage.markets_in_table, user);

    let index = 0;
    let length = vector::length(user_markets_in);

    // Need to make a copy to loop and then store the values again
    let markets_in_copy = vector::empty<String>();

    // Will store the total value in usd for collateral and borrows.
    let total_collateral_in_usd = 0;
    let total_borrows_in_usd = 0;
    
    while(index < length) {
      // Get the key
      let key = vector::pop_back(user_markets_in);
      // Put it back in the copy
      vector::push_back(&mut markets_in_copy, key);

      // If it is the market being modified. The one the user is trying to borrow or withdraw
      let is_modified_market = key == modified_market_key;

      // Get the user account
      let account = table::borrow(table::borrow(&account_storage.accounts_table, key), user);

      // Get the market data
      let market_data = borrow_mut_market_data(market_table, key);
      
      // Get the nominal collateral and borrow balance
      let (_collateral_balance, _borrow_balance) = get_account_balances_internal(
        market_data,
        account, 
        interest_rate_model_storage, 
        dinero_storage, 
        key, 
        ipx_per_epoch,
        total_allocation_points, 
        ctx
      );

      // If it is the modified market, remove the amount he is trying to withdraw
      let collateral_balance = if (is_modified_market) { _collateral_balance - withdraw_coin_value } else { _collateral_balance };
      // If it is the modified market, add the amount the user is trying to loan
      let borrow_balance = if (is_modified_market) { _borrow_balance + borrow_coin_value } else { _borrow_balance };

      // Get the price of the Coin
      let price_normalized = get_price(oracle_storage, key);

      // Make sure the price is not zero
      assert!(price_normalized != 0, ERROR_ZERO_ORACLE_PRICE);

      // Update the collateral and borrow
      total_collateral_in_usd = total_collateral_in_usd + fmul(fmul(collateral_balance, price_normalized), market_data.ltv);
      total_borrows_in_usd = total_borrows_in_usd + fmul(borrow_balance, price_normalized);

      // increment the index
      index = index + 1;
    };

    // Restore the markets in
    table::remove(&mut account_storage.markets_in_table, user);
    table::add(&mut account_storage.markets_in_table, user, markets_in_copy);

    // Make sure the user is solvent
    total_collateral_in_usd > total_borrows_in_usd
  }
}