require "./support/page_fixture"

module Caramel::Checks
  # Follows the recipe Submit the form your view renders (website page forms) step by step.
  class PageForms < PageFixture
    CSRF  = %(input type: "hidden", name: "_csrf", value: @csrf_token)
    STRAY = %(\n        input type: "hidden", name: "operation_key", value: "draft")

    def initialize
      super("forms", "bookshelf")
    end

    def proves : String
      "the rendered-form recipe submits the new book form as the page renders it, " \
      "and its spec fails on a hidden field the contract does not declare, " \
      "which the generated spec misses"
    end

    def follow : Nil
      # 01 · Create the application and its Book
      create
      made = frappe("make", "resource", "Book", "title:string", "author:string", "in_print:bool")
      assert!(made.stdout.includes?("Generated app/models/book.cr\n"), made.stdout)
      migrate(1)
      # 02 · Read the form the page rendered
      copy(["spec/support/rendered_form.cr"])
      # 03 · Submit the new book form
      copy(["spec/requests/book_form_spec.cr"])
      corretto(["spec/requests/book_form_spec.cr"])
      # Prove it
      prove
      catches_undeclared_field
    end

    # A hidden field the Create contract does not declare: the generated spec,
    # which posts params it builds itself, passes; the rendered-form spec fails.
    private def catches_undeclared_field : Nil
      view = File.join(project, "app/views/books/form.cr")
      original = File.read(view)
      assert!(original.includes?(CSRF), original)
      File.write(view, original.sub(CSRF, CSRF + STRAY))
      begin
        corretto(["spec/requests/books_spec.cr"])
        failed = attempt([@frappe, "corretto", "spec/requests/book_form_spec.cr"],
          chdir: project, timeout: 600.seconds)
        output = failed.stdout + failed.stderr
        assert!(!failed.success? && output.includes?("Expected status 303, got 422"), output)
      ensure
        File.write(view, original)
      end
    end
  end
end

begin
  Caramel::Checks::PageForms.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
