# SweetTalk with caramel/tenancy on PostgreSQL (ADR 0033): tenanted rows, keys, jobs,
# deadlines and channels, central contexts shared by every tenant, and the generated
# names and keys.
require "./support/app"

alias Catalogue = TenantShop::Catalogue
alias Ordering = TenantShop::Ordering
alias Fulfilment = TenantShop::Fulfilment
alias Reporting = TenantShop::Reporting

module TenancySpecs
  TENANTED = %w[fulfilment_labels fulfilment_parcels ordering_events ordering_holds
    ordering_order_lines ordering_orders ordering_sales stock_crates]
  LAPSE     = "TenantShop::Ordering::Hold::LapseDeadline"
  TOTALS    = "TenantShop::Reporting::Totals::WhenOrderingOrderPlaced"
  PLACED    = "sweettalk.ordering.order.placed"
  NO_TENANT = "TenantShop::Ordering::Rows::Order is tenanted, but no tenant is bound."
  CARRIED   = <<-SQL
    SELECT payload->>'caramel_tenant' AS tenant FROM caramel_jobs
    WHERE class_name = $1 ORDER BY id
    SQL
  ERRORS = <<-SQL
    SELECT last_error FROM caramel_jobs WHERE payload->>'caramel_tenant' = $1 ORDER BY id
    SQL
  SOLD = <<-SQL
    SELECT account_id, sold FROM ordering_sales WHERE tea_id = $1 ORDER BY account_id
    SQL
  LOGGED = <<-SQL
    SELECT account_id AS tenant, aggregate, name, subject_id AS subject
    FROM ordering_events ORDER BY id
    SQL
  HOLDS = <<-SQL
    SELECT count(*) AS value FROM ordering_holds WHERE slot_order = $1
    SQL

  # The tenant id each job of *class_name* carries, in the order they were enqueued.
  def self.carried(class_name : String) : Array(String?)
    SugarORM.sql(CARRIED, class_name, as: {tenant: String?}).map(&.[:tenant])
  end

  def self.table(name : String) : SugarORM::Catalog::Table
    SugarORM::Catalog.declared.find! { |table| table.name == name }
  end

  # Each foreign key of *table* as {name, columns, referenced columns}.
  def self.keys(table : String) : Array({String, Array(String), Array(String)})
    self.table(table).foreign_keys.map do |key|
      {key.name, key.columns, key.references_columns}
    end.sort!
  end

  # Waits up to *within* for one payload in *mailbox*, or nil.
  def self.received(mailbox : Channel(String), within : Time::Span) : String?
    select
    when payload = mailbox.receive
      payload
    when timeout(within)
      nil
    end
  end
end

describe "SweetTalk with tenancy" do
  it "keeps an order created in acme out of globex" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      order = Caramel::Tenancy.with(acme) do
        Ordering::Order.open("ada").tap(&.add(sencha, 2))
      end

      Caramel::Tenancy.with(globex) do
        Ordering::Order.find?(order.id).should be_nil
        Ordering::Order.all.should be_empty
      end
      Caramel::Tenancy.with(acme) { Ordering::Order.find?(order.id).try(&.id).should eq(order.id) }
    end
  end

  it "keeps a kernel's rows in their tenant" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      crate = Caramel::Tenancy.with(acme) { Ordering.stock(3) }
      Caramel::Tenancy.with(acme) { Fulfilment.crate_tins(crate).should eq(3) }
      Caramel::Tenancy.with(globex) do
        expect_raises(SweetTalk::Missing) { Fulfilment.crate_tins(crate) }
      end
    end
  end

  it "reads a specification in the bound tenant only" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      orders = [acme, globex].map do |account|
        Caramel::Tenancy.with(account) do
          Ordering::Order.open("ada").tap(&.add(sencha, 2)).tap(&.place)
        end
      end
      [acme, globex].map do |account|
        Caramel::Tenancy.with(account) do
          Ordering::Order.all(satisfying: Ordering::Live).map(&.id)
        end
      end.should eq(orders.map { |order| [order.id] })
    end
  end

  it "counts the bound tenant's orders only" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      [acme, globex].each do |account|
        Caramel::Tenancy.with(account) { Ordering::Order.open("ada").tap(&.add(sencha, 2)).place }
      end
      [acme, globex].map do |account|
        Caramel::Tenancy.with(account) { Ordering::Order.placed_count }
      end.should eq([1, 1])
    end
  end

  it "refuses tenanted reads with no tenant bound" do
    SweetTalkTenancySpec.rolled_back do
      acme = SweetTalkTenancySpec.account("acme")
      order = Caramel::Tenancy.with(acme) { Ordering::Order.open("ada") }

      expect_raises(SugarORM::Tenancy::Missing, TenancySpecs::NO_TENANT) do
        Ordering::Order.find?(order.id)
      end
    end
  end

  it "leaves a central context's rows unscoped" do
    SweetTalkTenancySpec.rolled_back do
      acme = SweetTalkTenancySpec.account("acme")
      SweetTalkTenancySpec.tea("Sencha")

      Catalogue::Tea.all.map(&.name).should eq(["Sencha"])
      Caramel::Tenancy.with(acme) { Catalogue::Tea.all.map(&.name).should eq(["Sencha"]) }
    end
  end

  it "names each aggregate's tenant, read across tenants with without" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      orders = [acme, globex].map do |account|
        Caramel::Tenancy.with(account) { Ordering::Order.open("ada") }
      end

      ids = [acme.id, globex.id]
      orders.map(&.tenant_id).should eq(ids)
      Caramel::Tenancy.without { Ordering::Order.all.map(&.tenant_id) }.should eq(ids)
      Caramel::Tenancy.without { Ordering::Order.all.map(&.tenant.slug) }.should eq(%w[acme globex])
    end
  end

  it "names the bound tenant of an aggregate not yet saved" do
    SweetTalkTenancySpec.rolled_back do
      acme = SweetTalkTenancySpec.account("acme")
      Caramel::Tenancy.with(acme) { Ordering::Order.new("ada").tenant_id }.should eq(acme.id)
    end
  end

  it "lets a tenanted aggregate reference a central one" do
    SweetTalkTenancySpec.rolled_back do
      acme = SweetTalkTenancySpec.account("acme")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      order = SweetTalkTenancySpec.place(acme, sencha, 2)

      key = {"fk_ordering_order_lines_tea_id", ["tea_id"], ["id"]}
      TenancySpecs.keys("ordering_order_lines").should contain(key)
      Caramel::Tenancy.with(acme) do
        Ordering::Order.find(order.id).lines.map(&.tea).should eq([sencha.id])
      end
    end
  end

  it "totals a tenanted event in a central projection across tenants" do
    SweetTalkTenancySpec.rolled_back do |connection|
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      SweetTalkTenancySpec.place(acme, sencha, 2)
      SweetTalkTenancySpec.place(globex, sencha, 2)

      TenancySpecs.carried(TenancySpecs::TOTALS).should eq([acme.id.to_s, globex.id.to_s])
      SweetTalkTenancySpec.drain(connection)
      Caramel::Tenancy.with(acme) do
        Reporting::Totals.all.map { |row| {row.tea, row.tins} }.should eq([{sencha.id.raw, 4}])
      end
    end
  end

  it "publishes a notification on the tenant's channel" do
    SweetTalkTenancySpec.committed do
      runtime = SweetTalkTenancySpec.url(SweetTalkTenancySpec::RUNTIME_URL)
      broker = Caramel::ColdBrew::Broker.new(runtime)
      Caramel::ColdBrew.broker = broker
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      in_acme, in_globex = Channel(String).new(4), Channel(String).new(4)
      mailboxes = [{acme, in_acme}, {globex, in_globex}]
      begin
        mailboxes.each do |(tenant, mailbox)|
          Caramel::Tenancy.with(tenant) do
            Caramel::ColdBrew.subscribe(TenancySpecs::PLACED, mailbox)
          end
        end
        order = SweetTalkTenancySpec.place(acme, sencha, 2)

        payload = TenancySpecs.received(in_acme, 1.second) || fail "no notification in acme"
        JSON.parse(payload).should eq(JSON.parse(%({"subject":#{order.id}})))
        TenancySpecs.received(in_globex, 1.second).should be_nil
      ensure
        mailboxes.each do |(tenant, mailbox)|
          Caramel::Tenancy.with(tenant) do
            Caramel::ColdBrew.unsubscribe(TenancySpecs::PLACED, mailbox)
          end
        end
        broker.close
        Caramel::ColdBrew.broker = nil
      end
    end
  end

  it "names the tenant column after the model" do
    tables = SugarORM::Catalog.declared
    columned = tables.select { |table| table.columns.any? { |column| column.name == "account_id" } }
    indexed = tables.select do |table|
      table.indexes.any? { |index| index.name == "index_#{table.name}_on_account_id_and_id" }
    end

    columned.map(&.name).sort!.should eq(TenancySpecs::TENANTED)
    indexed.map(&.name).sort!.should eq(TenancySpecs::TENANTED)
  end

  it "keeps one Sales row per tenant for one central tea" do
    SweetTalkTenancySpec.rolled_back do |connection|
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      SweetTalkTenancySpec.place(acme, sencha, 2)
      SweetTalkTenancySpec.place(globex, sencha, 2)
      SweetTalkTenancySpec.drain(connection)

      sold = SugarORM.sql(TenancySpecs::SOLD, sencha.id.raw, as: {account_id: Int64, sold: Int32})
      sold.map(&.values).should eq([{acme.id, 2}, {globex.id, 2}])
      {acme, globex}.each do |tenant|
        Caramel::Tenancy.with(tenant) { Ordering::Sales.all.size.should eq(1) }
      end
    end
  end

  it "logs each tenant's events in its own rows, and a shared kernel's in the sharer's log" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      order = SweetTalkTenancySpec.place(acme, sencha, 2)
      other = SweetTalkTenancySpec.place(globex, sencha, 3)
      crate = Caramel::Tenancy.with(acme) { Ordering.stock(1) }
      Caramel::Tenancy.with(acme) { Ordering.fill(crate, 4) }

      logged = SugarORM.sql(TenancySpecs::LOGGED, as: {tenant: Int64, aggregate: String,
                                                       name: String, subject: Int64?})
      logged.map(&.values).should eq([
        {acme.id, "order", "placed", order.id.raw}, {globex.id, "order", "placed", other.id.raw},
        {acme.id, "stock_crate", "filled", crate.raw},
      ])
      Caramel::Tenancy.with(acme) do
        Ordering.logged(Ordering::Order::Placed).map(&.order_id).should eq([order.id])
        Ordering.logged(TenantShop::Stock::Crate::Filled).map(&.tins).should eq([5])
      end
      Caramel::Tenancy.with(globex) do
        Ordering.logged(Ordering::Order::Placed).map(&.lines.first.tins).should eq([3])
      end
      expect_raises(SugarORM::Tenancy::Missing) { Ordering.logged }
    end
  end

  it "rebuilds the bound tenant's projection rows from its log" do
    SweetTalkTenancySpec.rolled_back do |connection|
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      SweetTalkTenancySpec.place(acme, sencha, 2)
      SweetTalkTenancySpec.place(globex, sencha, 3)
      SweetTalkTenancySpec.drain(connection)
      SugarORM.sql_exec("UPDATE ordering_sales SET sold = 0")

      Caramel::Tenancy.with(acme) { SweetTalk.rebuild(Ordering::Sales) }.should eq(1)
      sold = SugarORM.sql(TenancySpecs::SOLD, sencha.id.raw, as: {account_id: Int64, sold: Int32})
      sold.map(&.values).should eq([{acme.id, 2}, {globex.id, 0}])
    end
  end

  it "keeps one Hold row per tenant for one slot" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      sencha = SweetTalkTenancySpec.tea("Sencha")
      slot = Ordering::Slot.new(order: 424242, tea: sencha.id.raw)
      {acme, globex}.each do |tenant|
        Caramel::Tenancy.with(tenant) do
          SugarORM::Repo.transaction { SweetTalk.__sweettalk_work { Ordering::Hold[slot] } }
        end
      end

      holds = SugarORM.sql(TenancySpecs::HOLDS, 424242_i64, as: {value: Int64})
      holds.should eq([{value: 2_i64}])
    end
  end

  it "runs a policy in the tenant its event was emitted in" do
    SweetTalkTenancySpec.rolled_back do |connection|
      TenantShop::SEEN.clear
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      SweetTalkTenancySpec.place(acme, SweetTalkTenancySpec.tea("Sencha"), 2)
      SweetTalkTenancySpec.drain(connection)

      TenantShop::SEEN.should eq(["acme"])
      Caramel::Tenancy.with(acme) { Fulfilment::Parcel.all.size.should eq(1) }
      Caramel::Tenancy.with(globex) { Fulfilment::Parcel.all.size.should eq(0) }
    end
  end

  it "fires a deadline in the tenant that armed it" do
    SweetTalkTenancySpec.rolled_back do |connection|
      acme = SweetTalkTenancySpec.account("acme")
      order = SweetTalkTenancySpec.place(acme, SweetTalkTenancySpec.tea("Sencha"), 2)
      SweetTalkTenancySpec.drain(connection)

      TenancySpecs.carried(TenancySpecs::LAPSE).should eq([acme.id.to_s])
      SweetTalkTenancySpec.drain(connection, true)
      Caramel::Tenancy.with(acme) { Ordering::Order.find(order.id).cancelled?.should be_true }
    end
  end

  it "fails a job whose tenant was deleted" do
    SweetTalkTenancySpec.rolled_back do |connection|
      initech = SweetTalkTenancySpec.account("initech")
      SweetTalkTenancySpec.place(initech, SweetTalkTenancySpec.tea("Sencha"), 2)
      %w[ordering_order_lines ordering_orders ordering_events].each do |table|
        SugarORM.sql_exec("DELETE FROM #{table} WHERE account_id = $1", initech.id)
      end
      SugarORM.sql_exec("DELETE FROM accounts WHERE id = $1", initech.id)
      Caramel::ColdBrew.drain_queue(connection)

      gone = "Caramel::Tenancy::Gone: The tenant #{initech.id} this job was enqueued in no " \
             "longer exists"
      errors = SugarORM.sql(TenancySpecs::ERRORS, initech.id.to_s, as: {last_error: String?})
      errors.size.should eq(4)
      errors.each { |row| row[:last_error].to_s.should start_with(gone) }
    end
  end

  it "gives an entity table composite keys" do
    TenancySpecs.keys("ordering_order_lines").should eq([
      {"fk_ordering_order_lines_account_id", ["account_id"], ["id"]},
      {"fk_ordering_order_lines_order_id", ["order_id", "account_id"], ["id", "account_id"]},
      {"fk_ordering_order_lines_tea_id", ["tea_id"], ["id"]},
    ])
  end

  it "keeps a unique value unique within each tenant, so two tenants may share it" do
    SweetTalkTenancySpec.rolled_back do
      acme, globex = SweetTalkTenancySpec.account("acme"), SweetTalkTenancySpec.account("globex")
      [acme, globex].each do |account|
        Caramel::Tenancy.with(account) { Fulfilment::Label.create(code: "FRAGILE") }
      end
      Caramel::Tenancy.with(acme) do
        expect_raises(SweetTalk::Refusal, "Label code must be unique") do
          Fulfilment::Label.create(code: "FRAGILE")
        end
        Fulfilment::Label.all.size.should eq(1)
      end
      table = SugarORM::Catalog.declared.find! { |declared| declared.name == "fulfilment_labels" }
      table.indexes.find! { |index| index.name == "index_fulfilment_labels_on_code" }.columns
        .should eq(["code", "account_id"])
    end
  end

  it "migrates to a clean diff" do
    snapshot = SugarORM::Introspection.read(SweetTalkTenancySpec.owner)
    SugarORM::Differ.diff(SugarORM::Catalog.declared, snapshot).clean?.should be_true
  end
end
