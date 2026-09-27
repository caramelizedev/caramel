require "spec"
require "../../src/caramel/database"
require "../fixtures/models/application_record"
require "../fixtures/models/identity_record"

url = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"

describe "Typed models with PostgreSQL" do
  it "saves models without timestamps, including an identity-only record" do
    db = Caramel::Database.open(url)
    runtime = Caramel::Database.open(ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"])
    Caramel::Model.database = runtime
    begin
      db.exec("CREATE TABLE typed_identities (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)")
      db.exec("CREATE TABLE typed_untimed (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL)")
      db.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON typed_identities, typed_untimed TO caramel_model_spec")
      db.exec("GRANT USAGE, SELECT ON SEQUENCE typed_identities_id_seq, typed_untimed_id_seq TO caramel_model_spec")
      item = IdentityRecord.new
      item.save.should be_true
      id = item.id.not_nil!
      item.save.should be_true
      IdentityRecord.find(id).not_nil!.id.should eq(id)
      db.exec("DELETE FROM typed_identities WHERE id = $1", id)
      item.save.should be_false
      item.errors["_base"].should eq(["Record no longer exists"])
      db.query_one("SELECT count(*) FROM typed_identities", as: Int64).should eq(0_i64)
      untimed = UntimedRecord.new(name: "first")
      untimed.save.should be_true
      untimed.name = "updated"
      untimed.save.should be_true
      UntimedRecord.find(untimed.id.not_nil!).not_nil!.name.should eq("updated")
      untimed.delete.should be_true
    ensure
      db.exec("DROP TABLE IF EXISTS typed_identities, typed_untimed")
      runtime.close
      db.close
    end
  end

  it "persists typed records with bound values, timestamps and explicit missing-row results" do
    db = Caramel::Database.open(url)
    runtime = Caramel::Database.open(ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"])
    Caramel::Model.database = runtime
    begin
      db.exec("CREATE TABLE typed_books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL, author text NOT NULL, created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP)")
      db.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON typed_books TO caramel_model_spec")
      db.exec("GRANT USAGE, SELECT ON SEQUENCE typed_books_id_seq TO caramel_model_spec")
      runtime.query_one("SELECT current_user", as: String).should eq("caramel_model_spec")
      expect_raises(PQ::PQError) { runtime.exec("CREATE TABLE forbidden_model_ddl (id int)") }
      book = Book.new(title: "'); DROP TABLE typed_books; --", author: "An author")
      book.save.should be_true
      id = book.id.not_nil!
      book.created_at.should_not be_nil
      book.updated_at.should_not be_nil
      Book.find(id).not_nil!.title.should eq(book.title)
      Book.where(title: book.title).order(created_at: :desc).limit(1).to_a.map(&.id).should eq([id])
      previous_update = book.updated_at.not_nil!
      book.title = "Changed"
      book.save.should be_true
      book.updated_at.not_nil!.should be >= previous_update
      Book.find(id).not_nil!.title.should eq("Changed")
      book.title = " "
      book.save.should be_false
      Book.find(id).not_nil!.title.should eq("Changed")
      book.title = "Valid again"
      book.delete.should be_true
      book.delete.should be_false
      book.save.should be_false
      Book.find(id).should be_nil
      Book.find(999_999_i64).should be_nil

      stale = Book.new(title: "Stale", author: "Reader")
      stale.save.should be_true
      db.exec("DELETE FROM typed_books WHERE id = $1", stale.id.not_nil!)
      stale.title = "Must not reinsert"
      stale.save.should be_false
      stale.errors["_base"].should eq(["Record no longer exists"])
      db.query_one("SELECT count(*) FROM typed_books", as: Int64).should eq(0_i64)
    ensure
      db.exec("DROP TABLE IF EXISTS typed_books")
      runtime.close
      db.close
    end
  end

  it "handles every supported scalar, null conditions and field declaration order" do
    db = Caramel::Database.open(url)
    runtime = Caramel::Database.open(ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"])
    Caramel::Model.database = runtime
    begin
      db.exec("CREATE TABLE typed_samples (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL, quantity integer NOT NULL, total bigint NOT NULL, active boolean NOT NULL, score double precision, note text, published_at timestamptz, created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP)")
      db.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON typed_samples TO caramel_model_spec")
      db.exec("GRANT USAGE, SELECT ON SEQUENCE typed_samples_id_seq TO caramel_model_spec")
      item = TypedSample.new(name: "Item", quantity: 2, total: 5_000_000_000_i64, active: false)
      item.save.should be_true
      item.score = 2.5
      item.published_at = Time.utc(2026, 9, 19)
      item.save.should be_true
      loaded = TypedSample.where(active: false).where(note: nil).order(id: :asc).to_a.first
      loaded.quantity.should eq(2)
      loaded.total.should eq(5_000_000_000_i64)
      loaded.score.should eq(2.5)
      loaded.note.should be_nil
      loaded.published_at.should eq(Time.utc(2026, 9, 19))
      loaded.delete.should be_true
    ensure
      db.exec("DROP TABLE IF EXISTS typed_samples")
      runtime.close
      db.close
    end
  end
end
