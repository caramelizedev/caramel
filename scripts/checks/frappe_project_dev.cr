require "./support/project_fixture"

module Caramel::Checks
  # `frappe dev` end to end on a fresh application and a clone of it: the
  # session's readiness, sign-in, cancellation of superseded compiles, error
  # pages, logs, traces and the runtime URL override. Its own application,
  # so it runs beside frappe-project rather than after it.
  class FrappeProjectDev < ProjectFixture
    def initialize
      super("caramel-frappe-dev-")
    end

    def execute(args : Array(String)) : Nil
      puts "Frappé dev fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      failed = true
      begin
        start
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        clone = clone_project("bookshelf-clone")
        command([@frappe, "setup"], chdir: clone)
        Dev.new(self, clone).check
        failed = false
      ensure
        finish(failed)
      end
    end
  end
end

require "./frappe_project_dev/dev"

begin
  Caramel::Checks::FrappeProjectDev.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
