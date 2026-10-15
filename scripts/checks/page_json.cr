require "./support/page_fixture"

module Caramel::Checks
  # Follows the recipe Read and write JSON (website page json) step by step.
  class PageJson < PageFixture
    def initialize
      super("json", "bookshelf")
    end

    def proves : String
      "the JSON recipe versions a generated Book, answers JSON with ETag and If-Match, " \
      "and passes its specs"
    end

    def follow : Nil
      # Needs: a generated Book resource
      create
      made = frappe("make", "resource", "Book", "title:string", "author:string")
      assert!(made.stdout.includes?("Generated app/models/book.cr\n"), made.stdout)
      assert!(made.stdout.includes?("Run frappe migrate to apply the new schema."), made.stdout)
      migrate(1)
      # 1 · Give the model a version
      copy(["app/models/book.cr"])
      migration = diff("add_book_lock_version")
      assert!(migration.includes?(%("lock_version" integer NOT NULL DEFAULT 0)), migration)
      migrate(1)
      # 2 · Send the version, then check it
      copy(["app/actions/books/show.cr", "app/actions/books/update.cr"])
      # Prove it
      copy(["spec/requests/books_json_spec.cr"])
      prove
    end
  end
end

begin
  Caramel::Checks::PageJson.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
