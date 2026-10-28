# SweetTalk's database constraints (ADR 0045): a unique index, a plain index and a check
# declared on an attribute or over an aggregate are PostgreSQL's, a violation is the
# refusal the declaration says, the first row stands, a refused command is rolled back and
# the aggregate reloaded, an entity is unique within its aggregate and may be replaced by
# one with the same value, and the migration the differ derives for an existing table
# builds the index concurrently and validates the check online, which the linter accepts.
require "./support/app"

module ConstraintsSpec
  INDEXES = "SELECT indexname AS name, indexdef AS definition FROM pg_indexes " \
            "WHERE tablename LIKE 'pantry\\_%' AND indexname LIKE 'index\\_%' ORDER BY indexname"

  def self.crate(label : String, code : String = label, quantity : Int32 = 1)
    Constrained::Pantry::Crate.create(label: label, code: code, owner: "pantry",
      quantity: quantity)
  end

  def self.adjustment(source_key : String, bundle : String)
    Constrained::Pantry::Adjustment.create(source_key: source_key, bundle: bundle)
  end

  # The declared tables, with the given index and check names left out of one table: how
  # the database looked before they were declared.
  def self.before(table : String, names : Array(String)) : Array(SugarORM::Catalog::Table)
    SugarORM::Catalog.declared.map do |declared|
      next declared unless declared.name == table
      declared.copy_with(indexes: declared.indexes.reject { |index| names.includes?(index.name) },
        checks: declared.checks.reject { |check| names.includes?(check.name) })
    end
  end
end

describe "SweetTalk's database constraints" do
  it "refuses a duplicate with the default sentence, and the first row stands" do
    SweetTalkSpec.rolled_back do
      first = ConstraintsSpec.crate("same", code: "one")
      expect_raises(SweetTalk::Refusal, "Crate label must be unique") do
        ConstraintsSpec.crate("same", code: "two")
      end
      Constrained::Pantry::Crate.all.map(&.id).should eq([first.id])
    end
  end

  it "refuses a duplicate with the declared sentence" do
    SweetTalkSpec.rolled_back do
      ConstraintsSpec.crate("one", code: "shared")
      expect_raises(SweetTalk::Refusal, "A crate with this code already exists.") do
        ConstraintsSpec.crate("two", code: "shared")
      end
    end
  end

  it "refuses a command that breaks an attribute's check, rolls it back and reloads" do
    SweetTalkSpec.rolled_back do
      crate = ConstraintsSpec.crate("full", quantity: 2)
      expect_raises(SweetTalk::Refusal, "A crate cannot hold less than nothing.") do
        crate.take 3
      end
      crate.quantity.should eq(2)
      Constrained::Pantry::Crate.find(crate.id).quantity.should eq(2)
      crate.take 2
      crate.quantity.should eq(0)
    end
  end

  it "refuses a command that renames a crate to a label another holds" do
    SweetTalkSpec.rolled_back do
      ConstraintsSpec.crate("taken", code: "one")
      crate = ConstraintsSpec.crate("free", code: "two")
      expect_raises(SweetTalk::Refusal, "Crate label must be unique") { crate.relabel "taken" }
      crate.label.should eq("free")
    end
  end

  it "keeps two attributes unique together" do
    SweetTalkSpec.rolled_back do
      ConstraintsSpec.adjustment("ledger", "march")
      ConstraintsSpec.adjustment("ledger", "april")
      ConstraintsSpec.adjustment("journal", "march")
      expect_raises(SweetTalk::Refusal, "That bundle already has an adjustment.") do
        ConstraintsSpec.adjustment("ledger", "march")
      end
      Constrained::Pantry::Adjustment.all.size.should eq(3)
    end
  end

  it "refuses a command that breaks a check over the aggregate's state" do
    SweetTalkSpec.rolled_back do
      adjustment = ConstraintsSpec.adjustment("ledger", "may")
      expect_raises(SweetTalk::Refusal, "A pending line carries no amounts.") do
        adjustment.debit 5
      end
      adjustment.debit.should eq(0)
      adjustment.post
      adjustment.debit 5
      Constrained::Pantry::Adjustment.find(adjustment.id).debit.should eq(5)
    end
  end

  it "keeps an entity unique within its aggregate, and lets one replace another" do
    SweetTalkSpec.rolled_back do
      shipment = Constrained::Pantry::Shipment.create
      other = Constrained::Pantry::Shipment.create
      shipment.pack "fragile"
      other.pack "fragile"
      expect_raises(SweetTalk::Refusal, "Parcel tag must be unique") { shipment.pack "fragile" }
      shipment.parcels.size.should eq(1)
      shipment.repack "fragile"
      shipment.pack "heavy"
      Constrained::Pantry::Shipment.find(shipment.id).parcels.map(&.tag)
        .should eq(["fragile", "heavy"])
    end
  end

  it "refuses two entities that swap their unique values, since the index is not deferred" do
    SweetTalkSpec.rolled_back do
      shipment = Constrained::Pantry::Shipment.create
      shipment.pack "first"
      shipment.pack "second"
      expect_raises(SweetTalk::Refusal, "Parcel tag must be unique") { shipment.swap_tags }
      shipment.parcels.map(&.tag).should eq(["first", "second"])
    end
  end

  it "declares the indexes, the tenant-free way, and maps each constraint to its sentence" do
    SweetTalkSpec.rolled_back do
      indexes = SugarORM.sql(ConstraintsSpec::INDEXES, as: {name: String, definition: String})
      indexes.map { |index| {index[:name], index[:definition].starts_with?("CREATE UNIQUE")} }
        .should eq([
          {"index_pantry_adjustments_on_bundle_and_state", false},
          {"index_pantry_adjustments_on_source_key_and_bundle", true},
          {"index_pantry_crates_on_code", true},
          {"index_pantry_crates_on_label", true},
          {"index_pantry_crates_on_owner", false},
          {"index_pantry_shipment_parcels_on_shipment_id", false},
          {"index_pantry_shipment_parcels_on_shipment_id_and_tag", true},
        ])
    end
    Constrained::Pantry::Crate::SWEETTALK_REFUSALS.should eq({
      "index_pantry_crates_on_label"          => "Crate label must be unique",
      "index_pantry_crates_on_code"           => "A crate with this code already exists.",
      "check_pantry_crates_quantity_69784f25" => "A crate cannot hold less than nothing.",
    })
    composite = "index_pantry_adjustments_on_source_key_and_bundle"
    pending = "check_pantry_adjustments_pending_is_zero_0f316047"
    Constrained::Pantry::Adjustment::SWEETTALK_REFUSALS.should eq({
      composite => "That bundle already has an adjustment.",
      pending   => "A pending line carries no amounts.",
    })
    Constrained::Pantry::Shipment::Parcel::SWEETTALK_REFUSALS.should eq({
      "index_pantry_shipment_parcels_on_shipment_id_and_tag" => "Parcel tag must be unique",
    })
  end

  it "leaves a constraint SweetTalk did not declare as the error it is" do
    SweetTalkSpec.owner.exec("CREATE UNIQUE INDEX pantry_crates_one_owner ON pantry_crates (owner)")
    begin
      SweetTalkSpec.rolled_back do
        ConstraintsSpec.crate("one")
        error = expect_raises(SugarORM::UniqueViolation) { ConstraintsSpec.crate("two") }
        error.constraint.should eq("pantry_crates_one_owner")
      end
    ensure
      SweetTalkSpec.owner.exec("DROP INDEX pantry_crates_one_owner")
    end
  end

  it "derives an online migration for an existing table, which the linter accepts" do
    before = ConstraintsSpec.before("pantry_crates",
      ["index_pantry_crates_on_label", "check_pantry_crates_quantity_69784f25"])
    plan = SugarORM::Differ.diff(SugarORM::Catalog.declared, before)
    plan.halts.should be_empty
    SugarORM::DDL.statements(plan.transactional).should eq([
      %(ALTER TABLE "pantry_crates" ADD CONSTRAINT "check_pantry_crates_quantity_69784f25" ) +
      %(CHECK (quantity >= 0) NOT VALID),
    ])
    SugarORM::DDL.statements(plan.online).should eq([
      %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_pantry_crates_on_label" ) +
      %(ON "pantry_crates" ("label")),
      %(ALTER TABLE "pantry_crates" VALIDATE CONSTRAINT "check_pantry_crates_quantity_69784f25"),
    ])
    migrations = [
      SugarORM::Migration.new(20261028000001_i64, "constrain_crates",
        SugarORM::DDL.statements(plan.transactional)),
      SugarORM::Migration.new(20261028000002_i64, "constrain_crates_concurrently",
        SugarORM::DDL.statements(plan.online)),
    ]
    SugarORM::Linter.lint(migrations).should be_empty
  end
end
