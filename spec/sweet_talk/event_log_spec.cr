# The event log on PostgreSQL (ADR 0048): one row per event in the command's or the
# service's transaction, the typed reader, pruning, a projection rebuilt from the log
# under its lock, and a policy that runs after a projection's handler, enqueued by it.
require "./support/app"

alias Invoicing = Billing::Invoicing

module EventLogSpec
  RAISED_BY_OWED      = "Billing::Invoicing::Owed::WhenInvoiceRaised"
  SETTLED_BY_OWED     = "Billing::Invoicing::Owed::WhenInvoiceSettled"
  RAISED_BY_INVOICING = "Billing::Invoicing::WhenInvoiceRaised"
  TABLE               = "invoicing_events"

  ROWS = <<-SQL
    SELECT id, event_id, aggregate, name, subject_id, actor, cause_id, flow_id,
           fields::text AS fields
    FROM invoicing_events ORDER BY id
    SQL
  JOBS = <<-SQL
    SELECT id, class_name, finished_at IS NOT NULL AS finished FROM caramel_jobs ORDER BY id
    SQL
  OWED = <<-SQL
    SELECT customer, raised, settled FROM invoicing_oweds ORDER BY customer
    SQL
  HOLD = "SELECT pg_advisory_lock($1, hashtext($2))"
  FREE = "SELECT pg_advisory_unlock($1, hashtext($2)) AS freed"

  SHAPE = {id: Int64, event_id: String, aggregate: String, name: String, subject_id: Int64?,
           actor: String?, cause_id: String?, flow_id: String, fields: String}

  def self.rows
    SugarORM.sql(ROWS, as: SHAPE)
  end

  def self.jobs : Array({id: Int64, class_name: String, finished: Bool})
    SugarORM.sql(JOBS, as: {id: Int64, class_name: String, finished: Bool})
  end

  def self.owed : Array({customer: String, raised: Int64, settled: Int64})
    SugarORM.sql(OWED, as: {customer: String, raised: Int64, settled: Int64})
  end

  def self.invoice(customer : String, total : Int64) : Invoicing::Invoice
    Invoicing::Invoice.raise_for(customer, Invoicing::Cents.new(total))
  end

  def self.settle(invoice : Invoicing::Invoice) : Nil
    invoice.settle(invoice.total)
  end

  # Moves every logged row's occurred_at back by *span*, to age it for pruning.
  def self.age(span : Time::Span) : Nil
    SugarORM.sql_exec("UPDATE invoicing_events SET occurred_at = occurred_at - " \
                      "make_interval(secs => $1)", span.total_seconds)
  end

  def self.drain(connection) : Int32
    Caramel::ColdBrew.drain_queue!(connection)
  end
end

describe "SweetTalk event log" do
  it "declares the log table with its columns and indexes, for the context that keeps one" do
    tables = SugarORM::Catalog.declared
    tables.map(&.name).select(&.ends_with?("_events")).should eq([EventLogSpec::TABLE])
    table = tables.find! { |declared| declared.name == EventLogSpec::TABLE }
    table.columns.map(&.name).should eq(%w[id event_id aggregate name subject_id occurred_at actor
      cause_id flow_id fields created_at])
    table.columns.find! { |column| column.name == "fields" }.sql_type.should eq("jsonb")
    table.indexes.map { |index| {index.columns, index.unique} }.should eq([
      {["event_id"], true}, {["flow_id"], false}, {["cause_id"], false},
      {["aggregate", "subject_id", "id"], false}, {["occurred_at"], false},
    ])
  end

  it "writes one row per event a command or a service emits, in that transaction" do
    SweetTalkSpec.rolled_back do
      invoice = SweetTalk.acting("clerk:1") { EventLogSpec.invoice("ada", 900) }
      Invoicing.close("2026-10")

      rows = EventLogSpec.rows
      rows.map { |row| {row[:aggregate], row[:name], row[:subject_id]} }.should eq([
        {"invoice", "raised", invoice.id.raw}, {"invoicing", "closed", nil},
      ])
      rows[0][:actor].should eq("clerk:1")
      rows[0][:cause_id].should be_nil
      rows[0][:flow_id].size.should eq(32)
      JSON.parse(rows[0][:fields]).should eq({"customer" => "ada", "total" => 900})
      JSON.parse(rows[1][:fields]).should eq({"period" => "2026-10"})
      rows.map(&.[:event_id]).uniq!.size.should eq(2)
    end
  end

  it "writes no row for a refused command" do
    SweetTalkSpec.rolled_back do
      invoice = EventLogSpec.invoice("ada", 900)
      expect_raises(SweetTalk::Refusal, "An invoice is settled by its total.") do
        invoice.settle(Invoicing::Cents.new(1))
      end
      EventLogSpec.rows.map(&.[:name]).should eq(["raised"])
    end
  end

  it "reads typed events newest last, by subject and since a time" do
    SweetTalkSpec.rolled_back do
      ada, bob = EventLogSpec.invoice("ada", 900), EventLogSpec.invoice("bob", 300)
      EventLogSpec.settle(ada)
      midway = Time.utc
      sleep 2.milliseconds
      EventLogSpec.settle(bob)

      raised = Invoicing.logged(Invoicing::Invoice::Raised)
      raised.map { |event| {event.customer, event.total.raw, event.invoice_id} }
        .should eq([{"ada", 900_i64, ada.id}, {"bob", 300_i64, bob.id}])
      Invoicing.logged(Invoicing::Invoice::Settled, subject: ada.id).map(&.customer)
        .should eq(["ada"])
      Invoicing.logged(Invoicing::Invoice::Settled, since: midway).map(&.customer)
        .should eq(["bob"])
      Invoicing.logged(Invoicing::Invoice::Raised, limit: 1).map(&.customer).should eq(["ada"])
      Invoicing.logged(subject: bob.id).map(&.class.name).should eq([
        "Billing::Invoicing::Invoice::Raised", "Billing::Invoicing::Invoice::Settled",
      ])
      Invoicing.logged.map(&.event_id).should eq(EventLogSpec.rows.map(&.[:event_id]))
    end
  end

  it "reads an event with the metadata it was logged with" do
    SweetTalkSpec.rolled_back do
      SweetTalk.acting("clerk:1") { Invoicing.close("2026-10") }
      row = EventLogSpec.rows.first
      closed = Invoicing.logged(Invoicing::Closed).first
      {closed.event_id, closed.actor, closed.flow_id, closed.period}
        .should eq({row[:event_id], "clerk:1", row[:flow_id], "2026-10"})
      closed.occurred_at.should be_close(Time.utc, 5.seconds)
    end
  end

  it "prunes the rows that occurred before a time, in chunks" do
    SweetTalkSpec.rolled_back do
      EventLogSpec.invoice("ada", 900)
      EventLogSpec.invoice("bob", 300)
      EventLogSpec.invoice("cyd", 100)
      EventLogSpec.age(2.days)
      Invoicing.close("2026-10")

      SweetTalk.prune_events(Invoicing, before: 1.day.ago, chunk: 2).should eq(3)
      EventLogSpec.rows.map(&.[:name]).should eq(["closed"])
      SweetTalk.prune_events(Invoicing, before: 1.day.ago).should eq(0)
    end
  end

  it "rebuilds a projection from the log, and enqueues nothing" do
    SweetTalkSpec.rolled_back do |connection|
      ada = EventLogSpec.invoice("ada", 900)
      EventLogSpec.invoice("bob", 300)
      EventLogSpec.settle(ada)
      EventLogSpec.drain(connection)
      before = EventLogSpec.owed
      before.should eq([{customer: "ada", raised: 900_i64, settled: 900_i64},
                        {customer: "bob", raised: 300_i64, settled: 0_i64}])

      jobs_before = SweetTalkSpec.count("caramel_jobs")
      SugarORM.sql_exec("UPDATE invoicing_oweds SET raised = 1, settled = 1")
      SugarORM.sql_exec("DELETE FROM invoicing_oweds WHERE customer = 'bob'")
      SweetTalk.rebuild(Invoicing::Owed).should eq(3)
      EventLogSpec.owed.should eq(before)
      SweetTalkSpec.count("caramel_jobs").should eq(jobs_before)
      EventLogSpec.drain(connection).should eq(0)
    end
  end

  it "refuses a rebuild while a job of the projection's handlers is queued" do
    SweetTalkSpec.rolled_back do
      EventLogSpec.invoice("ada", 900)
      queued = "1 of #{EventLogSpec::RAISED_BY_OWED}"
      expect_raises(SweetTalk::Refusal, "invoicing_oweds cannot be rebuilt while jobs of its " \
                                        "handlers are queued or running (#{queued})") do
        SweetTalk.rebuild(Invoicing::Owed)
      end
    end
  end

  it "takes the projection's advisory lock while it rebuilds" do
    SweetTalkSpec.committed do
      namespace = Caramel::ColdBrew::Scheduler::LOCK_NAMESPACE
      SweetTalkSpec.runtime.using_connection do |holder|
        holder.exec(EventLogSpec::HOLD, namespace, "invoicing_oweds")
        done = Channel(Int64).new
        spawn { done.send(SweetTalk.rebuild(Invoicing::Owed)) }
        select
        when replayed = done.receive
          fail "rebuilt #{replayed} events under another session's lock"
        when timeout(300.milliseconds)
        end
        holder.query_one(EventLogSpec::FREE, namespace, "invoicing_oweds", as: Bool).should be_true
        done.receive.should eq(0)
      end
    end
  end

  it "runs a handler that says after: once its predecessor's job has run, enqueued by it" do
    SweetTalkSpec.rolled_back do |connection|
      Invoicing.reminders.clear
      EventLogSpec.invoice("ada", 900)
      EventLogSpec.jobs.map(&.[:class_name]).should eq([EventLogSpec::RAISED_BY_OWED])

      EventLogSpec.drain(connection).should eq(2)
      jobs = EventLogSpec.jobs
      jobs.map { |job| {job[:class_name], job[:finished]} }.should eq([
        {EventLogSpec::RAISED_BY_OWED, true}, {EventLogSpec::RAISED_BY_INVOICING, true},
      ])
      jobs[1][:id].should be > jobs[0][:id]
      Invoicing.reminders.should eq(["ada owes 900"])
    end
  end

  it "never enqueues a follower whose predecessor was refused or rolled back" do
    SweetTalkSpec.rolled_back do |connection|
      Invoicing.reminders.clear
      EventLogSpec.invoice("ada", 900)
      SugarORM.sql_exec("UPDATE caramel_jobs SET failed_at = now(), last_error = 'stopped'")
      EventLogSpec.drain(connection).should eq(0)
      EventLogSpec.jobs.map(&.[:class_name]).should eq([EventLogSpec::RAISED_BY_OWED])
      Invoicing.reminders.should be_empty
    end
  end
end
