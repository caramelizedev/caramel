# What PostgreSQL checks of SweetTalk's values: every integer bound and string length
# is a CHECK constraint on each column that stores it, so a write that goes around the
# domain is refused too; a pattern, and a value with database_check: false, are checked
# in Crystal only. And the tables as PostgreSQL holds them match the declared ones, so
# `frappe db diff` derives no further migration.
require "./support/app"

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
  it "creates a check for every bounded value it stores, and none for a pattern or an opt-out" do
    SweetTalkSpec.rolled_back do
      checks = SugarORM.sql(<<-SQL, as: {name: String})
        SELECT conname AS name FROM pg_constraint
        WHERE contype = 'c' AND conname LIKE 'check\\_%' ORDER BY conname
        SQL
      checks.map(&.[:name]).should eq(%w[
        check_catalogue_teas_held check_catalogue_teas_price check_catalogue_teas_stock
        check_fulfilment_parcel_packings_tins check_ordering_order_lines_price
        check_ordering_order_lines_quantity check_ordering_orders_receipt_to_length_3_254
        check_shelf_bins_code_length_2_4 check_shelf_bins_size_depth
        check_shelf_bins_size_width check_shelf_boxes_count check_shelf_jars_count
        check_shelf_jars_size_depth check_shelf_jars_size_width check_store_teas_stock
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
        TeaShop::Catalogue::Rows::Tea.create!(name: "Sencha", price: 900_i64, stock: -5, held: 0)
      end
      bin = DatabaseChecksSpec.bin
      DatabaseChecksSpec.broken("UPDATE shelf_bins SET size_width = -1 WHERE id = $1", bin.id.raw)
        .should eq("check_shelf_bins_size_width")
      DatabaseChecksSpec.broken("UPDATE shelf_bins SET code = 'ABCDE' WHERE id = $1", bin.id.raw)
        .should eq("check_shelf_bins_code_length_2_4")
      Rules::Shelf::Bin.find(bin.id).code.raw.should eq("AB")
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
end
