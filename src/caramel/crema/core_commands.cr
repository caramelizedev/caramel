require "./commands"
require "./diagnose"
require "./jobs"
require "./ops_client"

module Caramel::Crema
  # What `jobs …` does: Cold Brew's queues, read from and repaired in PostgreSQL.
  module JobsCommand
    USAGE = "Usage: jobs [stats] | jobs failed [--limit=N] | jobs show ID | " \
            "jobs retry ID|--class=NAME"

    def self.run(arguments : Array(String)) : Int32
      if ENV["CARAMEL_ENV"]? == "test"
        abort("The jobs commands read a real queue; run them in development or production")
      end
      CommandLine.with_database(false) { |_, _| dispatch(arguments) }
    end

    private def self.dispatch(arguments : Array(String)) : Int32
      case arguments.first?
      when nil, "stats" then print_table(Jobs.stats)
      when "failed"     then print_table(Jobs.failed(limit(arguments)))
      when "show"       then show(arguments[1]?)
      when "retry"      then retry(arguments[1]?)
      else                   usage
      end
    end

    private def self.print_table(table : Table) : Int32
      puts table.to_text
      0
    end

    private def self.limit(arguments : Array(String)) : Int32
      flag = arguments.find(&.starts_with?("--limit="))
      flag.try(&.lchop("--limit=").to_i?) || 20
    end

    # A job's columns, including its last error, to the operator's terminal only.
    private def self.show(id : String?) : Int32
      number = id.try(&.to_i64?) || return usage
      table = Jobs.show(number)
      if table.empty?
        STDERR.puts("No job #{number}.")
        return 1
      end
      table.headers.zip(table.rows.first).each { |name, value| puts "#{name.ljust(12)} #{value}" }
      0
    end

    private def self.retry(target : String?) : Int32
      return usage unless target

      count = if target.starts_with?("--class=")
                Jobs.retry_class(target.lchop("--class="))
              else
                Jobs.retry_id(target.to_i64? || return usage)
              end
      if count == 0
        STDERR.puts("No failed job matches.")
        return 1
      end
      puts "Retried #{count} failed #{count == 1 ? "job" : "jobs"}."
      0
    end

    private def self.usage : Int32
      STDERR.puts(USAGE)
      2
    end
  end

  command("ops", "ops status|requests|fibers|metrics|tail|errors|error|traces|trace|" \
                 "debug-token|console [--socket=PATH]") do |arguments|
    OpsClient.new(arguments).run
  end

  command("jobs", "jobs [stats|failed|show ID|retry ID|--class=NAME]") do |arguments|
    JobsCommand.run(arguments)
  end

  command("db", "db diagnose") do |_|
    CommandLine.with_database(false) do |_, _|
      Diagnose.run(STDOUT) ? 0 : 1
    end
  end

  command("insights", "insights") do |_|
    STDERR.puts("The Crema recorder is off. " \
                "Add require \"caramel/crema/recorder\" to config/application.cr.")
    1
  end
end
