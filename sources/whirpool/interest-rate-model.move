module interest_protocol::interest_rate_model {

  use std::ascii::{String}; 

  use sui::tx_context::{TxContext};
  use sui::transfer;
  use sui::object::{Self, UID};
  use sui::table::{Self, Table};
  use sui::event;

  use interest_protocol::math::{fmul, fdiv, one};
  use interest_protocol::utils::{get_coin_info, get_epochs_per_year};

  friend interest_protocol::whirpool;

  // TODO: need to update to timestamps whenever they are implemented in the devnet


  struct InterestRateData has key, store {
    id: UID,
    base_rate_per_epoch: u64,
    multiplier_per_epoch: u64,
    jump_multiplier_per_epoch: u64,
    kink: u64
  }

  struct InterestRateModelStorage has key {
    id: UID,
    interest_rate_table: Table<String, InterestRateData>
  }

  struct NewInterestRateData<phantom T> has copy, drop {
    base_rate_per_epoch: u64,
    multiplier_per_epoch: u64,
    jump_multiplier_per_epoch: u64,
    kink: u64
  }

  fun init(ctx: &mut TxContext) {
      transfer::share_object(
        InterestRateModelStorage {
          id: object::new(ctx),
          interest_rate_table: table::new<String, InterestRateData>(ctx)
        }
      );
  }

  public fun get_borrow_rate_per_epoch(
    storage: &InterestRateModelStorage,
    market_key: String,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64
  ): u64 {
    get_borrow_rate_per_epoch_internal(storage, market_key, cash, total_borrow_amount, reserves)
  }

  public fun get_supply_rate_per_epoch(
    storage: &InterestRateModelStorage,
    market_key: String,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64,
    reserve_factor: u64
  ): u64 {
    let borrow_rate = fmul(get_borrow_rate_per_epoch_internal(storage, market_key, cash, total_borrow_amount, reserves), (one() as u64) - reserve_factor);

    fmul(get_utilization_rate_internal(cash, total_borrow_amount, reserves), borrow_rate)
  }

  fun get_borrow_rate_per_epoch_internal(
    storage: &InterestRateModelStorage,
    market_key: String,
    cash: u64,
    total_borrow_amount: u64,
    reserves: u64
    ): u64 {
      let utilization_rate = get_utilization_rate_internal(cash, total_borrow_amount, reserves);

      let data = table::borrow(&storage.interest_rate_table, market_key);

      if (data.kink >= utilization_rate) {
        fmul(utilization_rate, data.multiplier_per_epoch) + data.base_rate_per_epoch
      } else {
        let normal_rate = fmul(data.kink, data.multiplier_per_epoch) + data.base_rate_per_epoch;

        let excess_utilization = utilization_rate - data.kink;
        
        fmul(excess_utilization, data.jump_multiplier_per_epoch) + normal_rate
      }
    }

  fun get_utilization_rate_internal(cash: u64, total_borrow_amount: u64, reserves: u64): u64 {
    if (total_borrow_amount == 0) { 0 } else { 
      fdiv(total_borrow_amount, (cash + total_borrow_amount) - reserves)
     }
  }

  public(friend) fun set_interest_rate_data<T>(
    storage: &mut InterestRateModelStorage,
    base_rate_per_year: u64,
    multiplier_per_year: u64,
    jump_multiplier_per_year: u64,
    kink: u64,
    ctx: &mut TxContext
  ) {
    let key = get_coin_info<T>();

    let epochs_per_year = get_epochs_per_year();

    let base_rate_per_epoch = base_rate_per_year / epochs_per_year;
    let multiplier_per_epoch = multiplier_per_year / epochs_per_year;
    let jump_multiplier_per_epoch = jump_multiplier_per_year / epochs_per_year;

    if (table::contains(&storage.interest_rate_table, key)) {
      let data = table::borrow_mut(&mut storage.interest_rate_table, key); 

      data.base_rate_per_epoch = base_rate_per_epoch;
      data.multiplier_per_epoch = multiplier_per_epoch;
      data.jump_multiplier_per_epoch = jump_multiplier_per_epoch;
      data.kink = kink;
    } else {
      table::add(
        &mut storage.interest_rate_table,
        key,
        InterestRateData {
          id: object::new(ctx),
          base_rate_per_epoch,
          multiplier_per_epoch,
          jump_multiplier_per_epoch,
          kink
        }
      );
    };

    event::emit(
      NewInterestRateData<T> {
      base_rate_per_epoch,
      multiplier_per_epoch,
      jump_multiplier_per_epoch,
      kink
      }
    );
  }

  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
  }

  #[test_only]
  public fun set_interest_rate_data_test<T>(
    storage: &mut InterestRateModelStorage,
    base_rate_per_year: u64,
    multiplier_per_year: u64,
    jump_multiplier_per_year: u64,
    kink: u64,
    ctx: &mut TxContext
  ) {
    set_interest_rate_data<T>(storage, base_rate_per_year, multiplier_per_year, jump_multiplier_per_year, kink, ctx);
  }

  #[test_only]
  public fun get_interest_rate_data<T>(storage: &InterestRateModelStorage): (u64, u64, u64, u64) {
    let data = table::borrow(&storage.interest_rate_table, get_coin_info<T>());
    (data.base_rate_per_epoch, data.multiplier_per_epoch, data.jump_multiplier_per_epoch, data.kink)
  }
}