# What PostgreSQL checks of SweetTalk's values and lifecycles: every integer bound and
# string length is a CHECK constraint on each column that stores it, a closed list of
# words too, and every lifecycle one on its state column, so a write that goes around the
# domain is refused too; an optional value with parts has one that keeps its columns all
# set or all nil, named by its parts so that a part added is a new constraint; a declared
# `check` is one named by the hash of its SQL (ADR 0045); a pattern, and a value with
# database_check: false, are checked in Crystal only. And the tables as PostgreSQL holds
# them match the declared ones, so `frappe db diff` derives no further migration.
require "./support/app"

# Two values with parts that differ by one part, to see how their checks are named.
module DatabaseChecksProbe
  include SweetTalk

  context Probe, means: "values with parts, only to compare how their checks are named" do
    value Size, Int32, at_least: 0, means: "a measure"

    value Pair, means: "two measures" do
      part width : Size
      part depth : Size
    end

    value Triple, means: "the same two measures and a third" do
      part width : Size
      part depth : Size
      part height : Size
    end
  end
end

module DatabaseChecksSpec
  def self.bin(code = "AB") : Rules::Shelf::Bin
    size = Rules::Shelf::Size.new(width: Rules::Shelf::Count.new(2),
      depth: Rules::Shelf::Count.new(3))
    Rules::Shelf::Bin.create(stack: Rules::Shelf::Stack.new(1), size: size,
      code: Rules::Shelf::Code.new(code))
  end

  # Runs *sql* in its own savepoint and returns the check it broke.
  def self.broken(sql : String, *args) : String?
    SugarORM::Repo.transaction { SugarORM.sql_exec(sql, *args) }
    nil
  rescue error : SugarORM::CheckViolation
    error.constraint
  end
end

describe "SweetTalk's database checks" do
  it "creates a check for every bounded value it stores, every lifecycle, and none for a " \
     "pattern or an opt-out" do
    SweetTalkSpec.rolled_back do
      checks = SugarORM.sql(<<-SQL, as: {name: String})
        SELECT conname AS name FROM pg_constraint
        WHERE contype = 'c' AND conname LIKE 'check\\_%' ORDER BY conname
        SQL
      checks.map(&.[:name]).should eq(%w[
        check_billing_bills_amount check_billing_bills_state_16e92b19 check_catalogue_teas_held
        check_catalogue_teas_price check_catalogue_teas_roast_one_of_59746504
        check_catalogue_teas_stock check_counter_batches_opened_by_length_2_20
        check_counter_entries_amount
        check_counter_followups_followed_by_length_2_20
        check_counter_followups_followed_with_all_or_none_437ba1f3
        check_counter_followups_followed_with_cents
        check_counter_followups_followed_with_currency_one_of_3910bcb7
        check_counter_standings_last_leg_all_or_none_437ba1f3
        check_counter_standings_last_leg_cents
        check_counter_standings_last_leg_currency_one_of_3910bcb7
        check_counter_standings_last_settled_by_length_2_20
        check_counter_transfer_lines_paid_by_length_2_20
        check_counter_transfer_lines_share_all_or_none_437ba1f3
        check_counter_transfer_lines_share_cents
        check_counter_transfer_lines_share_currency_one_of_3910bcb7
        check_counter_transfers_amount_cents
        check_counter_transfers_amount_currency_one_of_3910bcb7
        check_counter_transfers_channel_one_of_3c7434c3
        check_counter_transfers_kind_one_of_897bbc40
        check_counter_transfers_leg_all_or_none_437ba1f3 check_counter_transfers_leg_cents
        check_counter_transfers_leg_currency_one_of_3910bcb7
        check_counter_transfers_opened_by_length_2_20 check_counter_transfers_reason_length_3_40
        check_counter_transfers_settled_by_length_2_20 check_counter_transfers_state_2d0246c7
        check_counter_vouchers_issuer_length_2_20 check_counter_vouchers_kind_one_of_897bbc40
        check_credit_loans_rate_between_0_and_1 check_credit_loans_spread_from_minus0_5
        check_credit_pricings_rate_between_0_and_1
        check_fulfilment_parcel_packings_tins check_fulfilment_parcels_state_ee51dbc2
        check_invoicing_invoices_state_048b3f84 check_invoicing_invoices_total
        check_lending_loans_term_all_or_none_5e0012d4
        check_money_vouchers_amount check_money_vouchers_state_b3ad369e
        check_ordering_holds_state_a8664243 check_ordering_order_lines_price
        check_ordering_order_lines_quantity check_ordering_orders_courier_length_2_30
        check_ordering_orders_gift_to_all_or_none_333c6ad0
        check_ordering_orders_receipt_to_length_3_254
        check_ordering_orders_state_ef9524ce check_ordering_sales_takings
        check_pantry_adjustments_pending_is_zero_0f316047 check_pantry_adjustments_state_ec1638eb
        check_pantry_crates_quantity_69784f25 check_pricing_teas_price
        check_shelf_bins_code_length_2_4 check_shelf_bins_size_depth check_shelf_bins_size_width
        check_shelf_boxes_count check_shelf_boxes_state_2ac5fa1a check_shelf_jars_count
        check_shelf_jars_size_depth check_shelf_jars_size_width check_shelf_jars_state_d37e3be8
        check_shelf_tabs_state_d74ee900 check_store_teas_stock
      ])
    end
  end

  it "needs no further migration once its tables exist" do
    snapshot = SugarORM::Introspection.read(SweetTalkSpec.owner)
    plan = SugarORM::Differ.diff(SugarORM::Catalog.declared, snapshot)
    (plan.transactional + plan.online).map(&.inspect).should eq([] of String)
    plan.halts.should be_empty
  end

  it "refuses a bound broken around the domain, through a schema or in SQL" do
    SweetTalkSpec.rolled_back do
      expect_raises(SugarORM::Invalid, "stock must be at least 0") do
        TeaShop::Catalogue::Rows::Tea.create!(name: "Sencha", price: 900_i64, stock: -5, held: 0,
          roast: "medium")
      end
      bin = DatabaseChecksSpec.bin
      DatabaseChecksSpec.broken("UPDATE shelf_bins SET size_width = -1 WHERE id = $1", bin.id.raw)
        .should eq("check_shelf_bins_size_width")
      DatabaseChecksSpec.broken("UPDATE shelf_bins SET code = 'ABCDE' WHERE id = $1", bin.id.raw)
        .should eq("check_shelf_bins_code_length_2_4")
      Rules::Shelf::Bin.find(bin.id).code.raw.should eq("AB")
    end
  end

  it "refuses a state written around the domain" do
    SweetTalkSpec.rolled_back do
      box = Rules::Shelf::Box.create(label: "boxed", count: Rules::Shelf::Count.new(0))
      DatabaseChecksSpec.broken("UPDATE shelf_boxes SET state = 'bogus' WHERE id = $1", box.id.raw)
        .should eq("check_shelf_boxes_state_2ac5fa1a")
      Rules::Shelf::Box.find(box.id).draft?.should be_true
    end
  end

  it "keeps a value with database_check: false in Crystal only" do
    SweetTalkSpec.rolled_back do
      expect_raises(SweetTalk::Refusal, "Stack must be at most 3") { Rules::Shelf::Stack.new(4) }
      bin = DatabaseChecksSpec.bin
      DatabaseChecksSpec.broken("UPDATE shelf_bins SET stack = 4 WHERE id = $1", bin.id.raw)
        .should be_nil
      expect_raises(SweetTalk::Refusal, "Stack must be at most 3") do
        Rules::Shelf::Bin.find(bin.id)
      end
    end
  end

  it "names the check of an optional value's parts by those parts, so a part added is a new one" do
    pair = DatabaseChecksProbe::Probe::Pair::SWEETTALK_OPTIONAL_CHECK[0]
    triple = DatabaseChecksProbe::Probe::Triple::SWEETTALK_OPTIONAL_CHECK[0]
    pair.should match(/\Aall_or_none_[0-9a-f]{8}\z/)
    triple.should match(/\Aall_or_none_[0-9a-f]{8}\z/)
    triple.should_not eq(pair)
    # FNV-1a of the sorted part names, "cents,currency", as a lifecycle's states are named.
    Ledger::Counter::Money::SWEETTALK_OPTIONAL_CHECK[0].should eq("all_or_none_437ba1f3")
  end
end
