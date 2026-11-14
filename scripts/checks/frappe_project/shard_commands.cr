require "random/secure"

module Caramel::Checks
  # The commands a shard contributes, on the generated application: it depends by path
  # on a copy of the fixture shard spec/fixtures/shards/demo, whose frappe.yml declares
  # a tool command that its program runs and commands that its code registers with the
  # application. The tool command comes first: it is what requires the shard.
  class FrappeProject < ProjectFixture
    # A command for the copy's manifest that the shard's code does not register.
    UNREGISTERED = <<-YAML
        - syntax: absent
          brief: Do what no code does
          description: Run a command the shard's code does not register.
          run: application\n
      YAML

    # What `demo:install` prints for an agent, in each project it writes to.
    INSTALLED = <<-TEXT
      Generated config/application.cr
      Generated config/demo.cr
      OK demo:install 2 files\n
      TEXT
    # What it says when config/demo.cr is already there.
    INSTALL_REFUSED = <<-MRDP
      ERR USAGE at frappe demo:install
      MSG: File already exists: config/demo.cr; source was preserved\n
      MRDP
    TOOL_BUILD = "Building the demo shard's tool program"

    def shard_commands : Nil
      shard = File.join(@root, "demo")
      fixture = File.join(@repo, "spec/fixtures/shards/demo")
      command(["/bin/cp", "-R", fixture, shard], echo: false)
      # A source no earlier run built, so that this run builds the tool program once.
      program = File.join(shard, "src/demo/frappe.cr")
      File.write(program, File.read(program) + "\n# Check run #{Random::Secure.hex(8)}.\n")
      depend_on_shard(shard)
      command([@frappe, "setup", "--no-migrate"], chdir: @project)
      second = second_project
      installed_shard
      reused_tool_build(second)
      refused_second_install
      listed_shard_commands
      ran_shard_commands
      manifest = File.join(shard, "frappe.yml")
      declared = File.read(manifest)
      unregistered_shard_command(manifest, declared)
      refused_shard_manifest(manifest, declared)
      File.write(manifest, declared)
      insights_replaced
    end

    # Adds the shard at *path* to the application's dependencies and its lock. The
    # application does not require it: the shard's tool command does that.
    private def depend_on_shard(path : String) : Nil
      manifest = File.join(@project, "shard.yml")
      dependency = "\ndependencies:\n  demo:\n    path: #{path}\n"
      File.write(manifest, File.read(manifest).sub("\ndependencies:\n", dependency))
      lock = File.join(@project, "shard.lock")
      File.write(lock, File.read(lock) + "\n  demo:\n    path: #{path}\n    version: 0.1.0\n")
      application = File.read(File.join(@project, "config/application.cr"))
      assert!(!application.includes?(%(require "./demo")), application)
    end

    # A second project that locks and holds the same shards: a copy of the application
    # with its lib/, never set up, since a tool command needs neither Latte nor .env.
    private def second_project : String
      second = clone_project("bookshelf-tools")
      library = ["/bin/cp", "-R", File.join(@project, "lib"), File.join(second, "lib")]
      command(library, echo: false)
      second
    end

    # The tool command in the application, which locks the shard and does not require it.
    private def installed_shard : Nil
      install = [@frappe, "demo:install", "Read the guides"]
      first = command(install, chdir: @project, echo: false, timeout: 300.seconds)
      assert!(first.stdout == INSTALLED, first.stdout + first.stderr)
      assert!(first.stderr.includes?(TOOL_BUILD), first.stderr)
      application = File.read(File.join(@project, "config/application.cr"))
      assert!(application.includes?(%(require "caramel"\nrequire "./demo"\n)), application)
      initializer = File.read(File.join(@project, "config/demo.cr"))
      written = initializer.starts_with?(%(require "demo"\n)) &&
                initializer.includes?(%(Demo::NOTES << "Read the guides"\n))
      assert!(written, initializer)
      puts "PASS: frappe demo:install builds the shard's tool program and runs it in an " \
           "application that does not require the shard: it writes config/demo.cr and " \
           "requires it after caramel in config/application.cr"
    end

    # The same command in the second project, where the build is the first project's.
    private def reused_tool_build(second : String) : Nil
      install = [@frappe, "demo:install", "Read the guides", "--human"]
      again = command(install, chdir: second, echo: false, timeout: 300.seconds)
      assert!(!again.stderr.includes?(TOOL_BUILD), again.stderr)
      next_block = "\nNext:\n  frappe demo:notes list  list the notes, with yours\n"
      person = again.stdout.starts_with?("Generated config/application.cr\n") &&
               again.stdout.ends_with?(next_block)
      assert!(person, again.stdout)
      assert!(File.file?(File.join(second, "config/demo.cr")), again.stdout)
      command(["/bin/rm", "-rf", second], echo: false)
      puts "PASS: a second project that locks the same shard runs frappe demo:install " \
           "without building the tool program again, and --human prints for a person"
    end

    private def refused_second_install : Nil
      application = File.join(@project, "config/application.cr")
      before = File.read(application)
      install = [@frappe, "demo:install", "Read the guides again"]
      refused = attempt(install, chdir: @project)
      reported = refused.status.exit_code == 1 && refused.stdout.empty? &&
                 refused.stderr == INSTALL_REFUSED
      assert!(reported, refused.stdout + refused.stderr)
      kept = File.read(File.join(@project, "config/demo.cr")).includes?(%("Read the guides"\n))
      assert!(kept && File.read(application) == before)
      puts "PASS: a second frappe demo:install refuses to overwrite config/demo.cr, " \
           "exits 1 and leaves both files as they were"
    end

    private def listed_shard_commands : Nil
      help = command([@frappe, "help"], chdir: @project, echo: false)
      group = <<-TEXT

        DEMO
          demo:greet      Greet someone by name
          demo:notes      List or add notes
          demo:database   Name the application's database
          demo:install    Add the shard to the application\n
        TEXT
      assert!(help.stdout.includes?(group) && help.stderr.empty?, help.stdout + help.stderr)
      listing = command([@frappe, "help", "demo"], chdir: @project, echo: false).stdout
      rows = ["  demo:greet       Greet someone by name\n", "  demo:notes list  List the notes\n",
              "  demo:notes add   Add a note\n",
              "  demo:install     Add the shard to the application\n"]
      assert!(rows.all? { |row| listing.includes?(row) }, listing)
      greet = "frappe demo:greet NAME [--loud]  # Print a greeting for NAME; " \
              "--loud prints it in capitals.\n"
      inside = command([@frappe, "agent-manifest"], chdir: @project, echo: false).stdout
      assert!(inside.includes?(greet) && inside.includes?("frappe demo:notes add TEXT  # "), inside)
      assert!(inside.includes?("frappe demo:install NOTE [--agent|--human]  # "), inside)
      outside = command([@frappe, "agent-manifest"], chdir: @projects, echo: false).stdout +
                command([@frappe, "help"], chdir: @projects, echo: false).stdout
      assert!(!outside.includes?("demo:"), outside)
      puts "PASS: in an application that depends on a shard with a frappe.yml, frappe help " \
           "lists the shard's group, frappe help demo its commands and frappe agent-manifest " \
           "each in full; outside the application none appear"
    end

    # The application now requires the shard, so it builds with the shard's commands.
    private def ran_shard_commands : Nil
      greet = [@frappe, "demo:greet"]
      loud = command(greet + ["Ada", "--loud"], chdir: @project, echo: false, timeout: 300.seconds)
      assert!(loud.stdout == "HELLO, ADA!\n", loud.stdout + loud.stderr)
      notes = command([@frappe, "demo:notes", "list"], chdir: @project, echo: false)
      listed = "Water the plants\nReturn the books\nRead the guides\n"
      assert!(notes.stdout == listed, notes.stdout)
      added = command([@frappe, "demo:notes", "add", "Post the letter"],
        chdir: @project, echo: false)
      assert!(added.stdout == "Added Post the letter.\n", added.stdout)
      nobody = attempt(greet + ["Nobody"], chdir: @project)
      failed = nobody.status.exit_code == 3 && nobody.stdout.empty? &&
               nobody.stderr == "Nobody is not a name.\n"
      assert!(failed, nobody.stdout + nobody.stderr)
      missing = attempt(greet, chdir: @project)
      usage = <<-MRDP
        ERR USAGE at frappe demo:greet
        MSG: missing NAME
        SYNTAX: frappe demo:greet NAME [--loud]\n
        MRDP
      assert!(missing.status.exit_code == 1 && missing.stderr == usage, missing.stderr)
      puts "PASS: frappe demo:greet and frappe demo:notes run the application's commands, " \
           "print what they print and exit with their status, the note the tool command " \
           "installed among them; " \
           "a missing argument is refused with the command's syntax before the application runs"
      reached_input_and_database
    end

    # An application command reads Frappé's standard input and the project's database.
    private def reached_input_and_database : Nil
      typed = command([@frappe, "demo:notes", "add", "-"],
        chdir: @project, echo: false, input: "Call the roaster\n")
      assert!(typed.stdout == "Added Call the roaster.\n", typed.stdout + typed.stderr)
      database = URI.parse(local_values(@project)["DATABASE_URL"]).path.lchop('/')
      named = command([@frappe, "demo:database"], chdir: @project, echo: false)
      assert!(named.stdout == "#{database}\n", named.stdout + named.stderr)
      puts "PASS: frappe demo:notes add - reads the note from standard input, and " \
           "frappe demo:database connects to the project's development database"
    end

    # A command the manifest declares and the shard's code does not register.
    private def unregistered_shard_command(manifest : String, declared : String) : Nil
      File.write(manifest, declared.sub("families:\n", UNREGISTERED + "families:\n"))
      absent = attempt([@frappe, "demo:absent"], chdir: @project, timeout: 300.seconds)
      report = "lib/demo/frappe.yml declares demo:absent, which the demo shard's code " \
               "does not register in the application.\n"
      reported = absent.status.exit_code == 1 && absent.stdout.empty? &&
                 absent.stderr.starts_with?(report)
      assert!(reported, absent.stdout + absent.stderr)
      puts "PASS: a command that a manifest declares and no code registers exits 1, " \
           "naming the manifest and the command"
    end

    # A manifest of a newer format: its commands are absent, and the built-ins run.
    private def refused_shard_manifest(manifest : String, declared : String) : Nil
      File.write(manifest, declared.sub("format: 1\n", "format: 2\n"))
      refusal = "lib/demo/frappe.yml: the manifest is format 2, and this Frappé reads format 1."
      asked = attempt([@frappe, "demo:greet", "Ada"], chdir: @project)
      refused = asked.status.exit_code == 1 && asked.stdout.empty? &&
                asked.stderr.starts_with?(refusal)
      assert!(refused, asked.stdout + asked.stderr)
      help = command([@frappe, "help"], chdir: @project, echo: false)
      builtin = help.stdout.includes?("\nGET STARTED\n") && !help.stdout.includes?("demo:")
      assert!(builtin && help.stderr.starts_with?(refusal), help.stdout + help.stderr)
      routes = command([@frappe, "routes", "books"], chdir: @project, echo: false)
      assert!(routes.stdout.includes?("App::Books::Show") && routes.stderr.empty?, routes.stderr)
      puts "PASS: a manifest of a newer format is reported with its file and the format " \
           "Frappé reads, in frappe help and when its commands are asked for, " \
           "and frappe routes runs beside it"
    end

    # The application requires the recorder, which takes `insights` over from its stub.
    private def insights_replaced : Nil
      binary = File.join(@project, ".caramel/application")
      usage = command([binary, "help"], chdir: @project, echo: false).stdout
      replaced = usage.scan("insights").size == 1 && usage.includes?("|insights [--since=")
      assert!(replaced, usage)
      commands = "|demo:greet NAME [--loud]|demo:notes list|add TEXT|demo:database"
      assert!(usage.includes?(commands), usage)
      puts "PASS: the application starts with the recorder's insights in place of the stub, " \
           "and its usage lists the shard's commands"
    end
  end
end
