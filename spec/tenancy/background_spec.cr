require "./support/app"

private alias Tenancy = Caramel::Tenancy
private alias Brew = Caramel::ColdBrew

# The slug each Record run saw, in run order.
private def runs : Array(String?)
  TenancySpec::Run.query.order_by(:id).to_a.map(&.slug)
end

# The next message on *updates*, or nil after *timeout*.
private def receive?(updates : Channel(String), timeout : Time::Span) : String?
  select
  when message = updates.receive
    message
  when timeout(timeout)
    nil
  end
end

# Publishes *payload* on *channel* in *account*, on a connection of its own,
# so the notification commits.
private def publish(account : TenancySpec::Account, channel : String, payload : String) : Nil
  SugarORM::Repo.using(TenancySpec.runtime) do
    Tenancy.with(account) { Brew.publish(channel, payload) }
  end
end

describe "A job" do
  it "runs in the tenant it was enqueued in" do
    acme = TenancySpec.account("acme")
    Tenancy.with(acme) { TenancySpec::Record.enqueue }
    TenancySpec.drain.should eq(1)
    runs.should eq(["acme"])
  end

  it "runs in no tenant when it was enqueued in none" do
    acme = TenancySpec.account("acme")
    TenancySpec::Record.enqueue
    Tenancy.with(acme) { TenancySpec.drain }
    runs.should eq([nil])
  end

  it "fails when its tenant no longer exists" do
    acme = TenancySpec.account("acme")
    Tenancy.with(acme) { TenancySpec::Record.enqueue }
    acme.delete
    failure = expect_raises(Brew::DrainFailure) { TenancySpec.drain }
    failure.failures.first.error.should be_a(Tenancy::Gone)
    runs.should be_empty
  end
end

# Writes `plan` in two tenants and a central `banner`.
private def seeded
  acme = TenancySpec.account("acme")
  globex = TenancySpec.account("globex")
  Tenancy.with(acme) { Caramel::Cache.write("plan", "gold") }
  Tenancy.with(globex) { Caramel::Cache.write("plan", "silver") }
  Caramel::Cache.write("banner", "hi")
  {acme, globex}
end

describe "The cache" do
  it "keeps each tenant's keys apart" do
    acme = TenancySpec.account("acme")
    globex = TenancySpec.account("globex")
    Tenancy.with(acme) { Caramel::Cache.write("plan", "gold") }
    Tenancy.with(globex) { Caramel::Cache.read("plan") }.should be_nil
    Tenancy.with(acme) { Caramel::Cache.read("plan") }.should eq("gold")
  end

  it "refuses a tenant-prefixed key when no tenant is bound" do
    message = "starts with t<id>:"
    expect_raises(ArgumentError, message) { Caramel::Cache.write("t5:plan", "x") }
    expect_raises(ArgumentError, message) { Caramel::Cache.read("t5:plan") }
    expect_raises(ArgumentError, message) { Caramel::Cache.delete("t5:plan") }
  end

  it "accepts names that only resemble the prefix" do
    Caramel::Cache.write("t5", "a")
    Caramel::Cache.write("task:1", "a")
    Caramel::Cache.write("t5x:a", "a")
    Brew.validate_channel!("t5:x")
  end

  it "lets without reach prefixed names" do
    acme = TenancySpec.account("acme")
    Tenancy.with(acme) { Caramel::Cache.write("plan", "gold") }
    Tenancy.without { Caramel::Cache.read("t#{acme.id}:plan") }.should eq("gold")
  end

  it "keeps a bound tenant inside its own prefix" do
    acme = TenancySpec.account("acme")
    globex = TenancySpec.account("globex")
    Tenancy.with(acme) { Caramel::Cache.write("t#{globex.id}:plan", "evil") }
    forged = "t#{acme.id}:t#{globex.id}:plan"
    Tenancy.without { Caramel::Cache.read(forged) }.should eq("evil")
    Tenancy.with(globex) { Caramel::Cache.read("plan") }.should be_nil
  end

  describe "clear" do
    it "deletes only the bound tenant's keys" do
      acme, globex = seeded
      Tenancy.with(acme) { Caramel::Cache.clear }
      Tenancy.with(acme) { Caramel::Cache.read("plan") }.should be_nil
      Tenancy.with(globex) { Caramel::Cache.read("plan") }.should eq("silver")
      Caramel::Cache.read("banner").should eq("hi")
    end

    it "deletes only untenanted keys when no tenant is bound" do
      acme, globex = seeded
      Caramel::Cache.clear
      Caramel::Cache.read("banner").should be_nil
      Tenancy.with(acme) { Caramel::Cache.read("plan") }.should eq("gold")
      Tenancy.with(globex) { Caramel::Cache.read("plan") }.should eq("silver")
    end

    it "deletes every key inside without" do
      seeded
      Tenancy.without { Caramel::Cache.clear }
      count = SugarORM.sql("SELECT count(*) AS value FROM caramel_cache", as: {value: Int64})
      count.first[:value].should eq(0)
    end
  end
end

describe "PubSub" do
  it "refuses a tenant-prefixed channel when no tenant is bound" do
    message = %(PubSub channel "t5:news" starts with t<id>:)
    broker = Brew::Broker.new(TenancySpec.url(TenancySpec::RUNTIME_URL))
    Brew.broker = broker
    begin
      expect_raises(ArgumentError, message) { Brew.publish("t5:news", "{}") }
      expect_raises(ArgumentError, message) { Brew.subscribe("t5:news", Channel(String).new) }
    ensure
      broker.close
      Brew.broker = nil
    end
  end

  it "delivers a channel's messages only to its own tenant's subscribers" do
    acme = TenancySpec.account("acme")
    globex = TenancySpec.account("globex")
    broker = Brew::Broker.new(TenancySpec.url(TenancySpec::RUNTIME_URL))
    Brew.broker = broker
    begin
      Tenancy.with(acme) do
        Brew.subscribe("news") do |updates|
          publish(globex, "news", "globex")
          publish(acme, "news", "acme")
          receive?(updates, 5.seconds).should eq("acme")
        end
      end
    ensure
      broker.close
      Brew.broker = nil
    end
  end
end

describe "Caramel::Tenancy.each" do
  it "visits every tenant once, with that tenant bound" do
    TenancySpec.account("acme")
    TenancySpec.account("globex")
    visited = [] of {String, String?}
    Tenancy.each do |account|
      visited << {account.slug, Tenancy.current?.try(&.slug)}
    end
    visited.sort_by(&.[0]).should eq([{"acme", "acme"}, {"globex", "globex"}])
  end
end
