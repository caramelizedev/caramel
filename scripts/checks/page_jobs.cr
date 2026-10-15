require "./support/page_fixture"

module Caramel::Checks
  # Follows the recipe Run a background job (website page jobs) step by step.
  class PageJobs < PageFixture
    READY = "Bookshelf worker is ready: queues default, imports; concurrency 4; scheduler on"

    def initialize
      super("jobs", "bookshelf")
    end

    def proves : String
      "the background job recipe enqueues in the action's transaction, drains the queue " \
      "in a spec, starts a worker on its queues, and passes its specs"
    end

    def follow : Nil
      # 01 · Create the application and its Book
      create
      made = frappe("make", "resource", "Book", "title:string", "author:string")
      assert!(made.stdout.includes?("Generated app/models/book.cr\n"), made.stdout)
      assert!(made.stdout.includes?("Run frappe migrate to apply the new schema."), made.stdout)
      migrate(1)
      # 02 · Write the job
      copy(["app/jobs/import_book.cr"])
      # 03 · Enqueue from an action
      copy(["app/actions/imports/create.cr", "config/routes.cr"])
      routes("imports", ["POST /imports App::Imports::Create title:String author:String"])
      # 04 · Drain the queue in a spec
      copy(["spec/requests/imports_spec.cr"])
      # 05 · Start a worker
      work
      # Prove it
      prove
    end

    # Runs the compiled application's `work` on both queues until it prints
    # the ready line, then stops it.
    private def work : Nil
      binary = File.join(@project, ".caramel/application")
      assert!(File.exists?(binary), "No compiled application at #{binary}")
      log = File.join(@root, "work.log")
      env = environment(local_values(@project).merge({"CARAMEL_ENV" => "development"}))
      worker = File.open(log, "w") do |output|
        Process.new(binary, ["work", "--queues=default,imports", "--concurrency=4"],
          chdir: @project, env: env, input: Process::Redirect::Close,
          output: output, error: output)
      end
      begin
        ready = Checks.wait_until(30.seconds, 50.milliseconds) do
          File.read(log).includes?(READY) || worker.terminated?
        end
        assert!(ready && File.read(log).includes?(READY), File.read(log))
      ensure
        Checks.stop(worker, 15.seconds)
      end
      puts File.read(log)
    end
  end
end

begin
  Caramel::Checks::PageJobs.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
