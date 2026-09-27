require "spec"
require "random/secure"
require "../../src/caramel/corretto"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
private CORRETTO_ADMIN_URL = ENV["CARAMEL_OWNED_ADMIN_URL"]? || raise "Run scripts/check integration; no owned admin connection provided"
private CORRETTO_OWNER_URL = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"

module CorrettoIntegration
  struct Note < SugarORM::Schema
    schema "corretto_notes" do
      field id : Int64, primary: true
      field title : String
      field customer : String?
    end
  end

  abstract struct Action < Caramel::Action
    def layout(page : Caramel::Page) : String
      "<!DOCTYPE html><html><head><title>#{Caramel::HTML.escape(page.title)}</title></head><body>#{page.body}</body></html>"
    end
  end

  # Registers the note's customer with Stripe, then stores the note.
  struct Create < Action
    contract do
      field title : String
    end

    def handle(contract : Contract)
      stripe = Caramel::Outbound.post("https://api.stripe.com/v1/customers", HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, URI::Params.encode({"description" => contract.title}))
      customer = stripe.success? ? JSON.parse(stripe.body)["id"].as_s : nil
      note = Note.create!(title: contract.title, customer: customer)
      morph("#notes", Caramel::HTML.escape("#{note.title} #{note.customer || "without customer"}"))
    end
  end

  Caramel::Router.draw do
    post "/notes", CorrettoIntegration::Create
  end
end

private def corretto_url(database : String) : String
  CORRETTO_OWNER_URL.sub("/caramel_spec?", "/#{database}?")
end

private def corretto_count(database : String, sql : String) : Int64
  observer = Caramel::Database.open(corretto_url(database), 1)
  begin
    observer.query_one(sql, as: Int64)
  ensure
    observer.close
  end
end

# A migrated template and worker 1 cloned from it, named as frappe corretto
# names them; the reset re-clones the worker the way Latte does.
private def with_corretto_worker(&)
  template = "caramel_spec_#{Random::Secure.hex(8)}"
  database = "#{template}_w1"
  admin = Caramel::Database.open(CORRETTO_ADMIN_URL, 1)
  begin
    admin.exec(%(CREATE DATABASE "#{template}" OWNER caramel_spec))
    owner = Caramel::Database.open(corretto_url(template), 1)
    begin
      owner.exec("CREATE TABLE corretto_notes (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL, customer text)")
    ensure
      owner.close
    end
    clone = %(CREATE DATABASE "#{database}" TEMPLATE "#{template}" OWNER caramel_spec)
    admin.exec(clone)
    reset = -> do
      admin.exec(%(DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)))
      admin.exec(clone)
      nil
    end
    worker = Corretto::Worker.new(corretto_url(database), corretto_url(database), reset)
    begin
      yield worker, database
    ensure
      worker.close
    end
  ensure
    admin.exec(%(DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)))
    admin.exec(%(DROP DATABASE IF EXISTS "#{template}" WITH (FORCE)))
    admin.close
  end
end

describe Corretto::Worker do
  it "rolls every example back to its savepoint, with the Repo bound to the example's connection" do
    with_corretto_worker do |worker, database|
      worker.run do
        CorrettoIntegration::Note.create!(title: "first")
        SugarORM::Repo.connection { |connection| connection.same?(worker.connection).should be_true }
        SugarORM::Repo.in_transaction?.should be_true
        SugarORM::Repo.transaction do
          CorrettoIntegration::Note.create!(title: "nested")
          SugarORM::Repo.rollback
        end
        CorrettoIntegration::Note.query.to_a.map(&.title).should eq(["first"])
        worker.connection.exec("CREATE TABLE rolled_back_ddl (id integer)")
        corretto_count(database, "SELECT count(*) FROM corretto_notes").should eq(0)
      end.should be_false
      worker.run do
        CorrettoIntegration::Note.query.count.should eq(0)
        worker.connection.query_one("SELECT to_regclass('rolled_back_ddl')::text", as: String?).should be_nil
      end.should be_false
      corretto_count(database, "SELECT count(*) FROM corretto_notes").should eq(0)
      worker.resets.should eq(0)
      expect_raises(Corretto::Error, "inside an example") { worker.connection }
    end
  end

  it "resets the worker when DDL escapes the transaction, and always after catalog examples" do
    with_corretto_worker do |worker, database|
      booted = worker.fingerprint
      leaked = worker.run do
        leak = Caramel::Database.open(corretto_url(database), 1)
        leak.exec("CREATE TABLE leaked_ddl (id integer)")
        leak.close
      end
      leaked.should be_true
      worker.resets.should eq(1)
      worker.current_fingerprint.should eq(booted)
      worker.run do
        worker.connection.query_one("SELECT to_regclass('leaked_ddl')::text", as: String?).should be_nil
      end.should be_false

      worker.run(catalog: true) do
        SugarORM::Repo.in_transaction?.should be_false
        # CONCURRENTLY is refused inside a transaction block: catalog examples run unwrapped.
        worker.connection.exec("CREATE INDEX CONCURRENTLY corretto_notes_title ON corretto_notes (title)")
        CorrettoIntegration::Note.create!(title: "committed")
        corretto_count(database, "SELECT count(*) FROM corretto_notes").should eq(1)
      end.should be_false
      worker.resets.should eq(2)
      worker.run do
        CorrettoIntegration::Note.query.count.should eq(0)
        worker.connection.query_one("SELECT to_regclass('corretto_notes_title')::text", as: String?).should be_nil
      end.should be_false
      worker.current_fingerprint.should eq(booted)
    end
  end

  it "serves in-process requests on the example's connection with wire-stubbed outbound calls" do
    with_corretto_worker do |worker, database|
      application = Caramel::Application.new(CorrettoIntegration::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://notes.caramel"))
      worker.run do
        Corretto.stub_wire("https://api.stripe.com/v1/customers", method: "POST").to_return(status: 200, fixture: "stripe/customer_created.json")
        client = Corretto::Client.new(application)
        db = worker.connection
        created = client.post("/notes", headers: {"HX-Request" => "true"}, params: {"title" => "Acme <Corp>"})
        created.should have_status(200)
        created.should render_partial("#notes", swap: "innerMorph")
        created.body.should contain("Acme &lt;Corp&gt; cus_Corretto123")
        db.should have_row(CorrettoIntegration::Note, title: "Acme <Corp>", customer: "cus_Corretto123")
        db.should_not have_row(CorrettoIntegration::Note, title: "Acme <Corp>", customer: nil)
        expect_raises(Spec::AssertionFailed, %(Expected CorrettoIntegration::Note to have a row where title: "Other"; none matched among 1 rows)) do
          db.should have_row(CorrettoIntegration::Note, title: "Other")
        end
        sent = Corretto.wire_requests.last
        {sent.method, sent.url, sent.body}.should eq({"POST", "https://api.stripe.com/v1/customers", "description=Acme+%3CCorp%3E"})

        Corretto.wire.reset
        client.post("/notes", params: {"title" => "Offline"}).should render_partial("#notes")
        db.should have_row(CorrettoIntegration::Note, title: "Offline", customer: nil)
        Corretto.wire_requests.map(&.url).should eq(["https://api.stripe.com/v1/customers"])
        corretto_count(database, "SELECT count(*) FROM corretto_notes").should eq(0)
      end.should be_false
      worker.run { CorrettoIntegration::Note.query.count.should eq(0) }
    end
  end
end
