module Caramel::Checks
  # The commands a shard contributes, on the generated application: it depends by path
  # on a copy of the fixture shard spec/fixtures/shards/demo, whose frappe.yml declares
  # commands that its code registers with the application.
  class FrappeProject < ProjectFixture
    # A command for the copy's manifest that the shard's code does not register.
    UNREGISTERED = <<-YAML
        - syntax: absent
          brief: Do what no code does
          description: Run a command the shard's code does not register.
          run: application\n
      YAML

    def shard_commands : Nil
      shard = File.join(@root, "demo")
      fixture = File.join(@repo, "spec/fixtures/shards/demo")
      command(["/bin/cp", "-R", fixture, shard], echo: false)
      depend_on_shard(shard)
      command([@frappe, "setup", "--no-migrate"], chdir: @project)
      listed_shard_commands
      completed_shard_commands(File.join(shard, "frappe.yml"))
      ran_shard_commands
      manifest = File.join(shard, "frappe.yml")
      declared = File.read(manifest)
      unregistered_shard_command(manifest, declared)
      refused_shard_manifest(manifest, declared)
      File.write(manifest, declared)
      insights_replaced
    end

    # Adds the shard at *path* to the application's dependencies, its lock and its requires.
    private def depend_on_shard(path : String) : Nil
      manifest = File.join(@project, "shard.yml")
      dependency = "\ndependencies:\n  demo:\n    path: #{path}\n"
      File.write(manifest, File.read(manifest).sub("\ndependencies:\n", dependency))
      lock = File.join(@project, "shard.lock")
      File.write(lock, File.read(lock) + "\n  demo:\n    path: #{path}\n    version: 0.1.0\n")
      application = File.join(@project, "config/application.cr")
      recorder = %(require "caramel/crema/recorder"\n)
      required = File.read(application).sub(recorder, recorder + %(require "demo"\n))
      assert!(required.includes?(%(require "demo"\n)), required)
      File.write(application, required)
    end

    private def listed_shard_commands : Nil
      help = command([@frappe, "help"], chdir: @project, echo: false)
      group = "\nDEMO\n  demo:greet      Greet someone by name\n" \
              "  demo:notes      List or add notes\n"
      assert!(help.stdout.includes?(group) && help.stderr.empty?, help.stdout + help.stderr)
      listing = command([@frappe, "help", "demo"], chdir: @project, echo: false).stdout
      rows = ["  demo:greet       Greet someone by name\n", "  demo:notes list  List the notes\n",
              "  demo:notes add   Add a note\n"]
      assert!(rows.all? { |row| listing.includes?(row) }, listing)
      greet = "frappe demo:greet NAME [--loud]  # Print a greeting for NAME; " \
              "--loud prints it in capitals.\n"
      inside = command([@frappe, "agent-manifest"], chdir: @project, echo: false).stdout
      assert!(inside.includes?(greet) && inside.includes?("frappe demo:notes add TEXT  # "), inside)
      outside = command([@frappe, "agent-manifest"], chdir: @projects, echo: false).stdout +
                command([@frappe, "help"], chdir: @projects, echo: false).stdout
      assert!(!outside.includes?("demo:"), outside)
      puts "PASS: in an application that depends on a shard with a frappe.yml, frappe help " \
           "lists the shard's group, frappe help demo its commands and frappe agent-manifest " \
           "each in full; outside the application none appear"
    end

    # What bash offers for `frappe demo:gr` with the script the built frappe prints, and
    # for `frappe demo:greet Ada --`.
    BASH_COMPLETION = <<-'BASH'
      eval "$("$FRAPPE" completion bash)"
      COMP_WORDS=("$FRAPPE" demo : gr); COMP_CWORD=3; _frappe
      printf '%s\n' "${COMPREPLY[@]}"
      COMP_WORDS=("$FRAPPE" demo : greet Ada --); COMP_CWORD=5; _frappe
      printf '%s\n' "${COMPREPLY[@]}"
      BASH

    private def completed_shard_commands(manifest : String) : Nil
      asked = [@frappe, "__complete", "de"]
      inside = command(asked, chdir: @project, echo: false)
      offered = inside.stdout.includes?("dev\t") && inside.stderr.empty? &&
                inside.stdout.ends_with?("demo:greet\tGreet someone by name\n" \
                                         "demo:notes\tList or add notes\n")
      assert!(offered, inside.stdout + inside.stderr)
      options = command([@frappe, "__complete", "demo:greet", "Ada", "--"],
        chdir: @project, echo: false)
      assert!(options.stdout == "--loud\n", options.stdout)
      outside = command(asked, chdir: @projects, echo: false)
      builtin = outside.stdout.includes?("dev\t") && !outside.stdout.includes?("demo:")
      assert!(builtin && outside.stderr.empty?, outside.stdout + outside.stderr)
      bash = command(["/bin/bash", "--norc", "--noprofile", "-c", BASH_COMPLETION],
        chdir: @project, echo: false, environment: environment({"FRAPPE" => @frappe}))
      assert!(bash.stdout == "greet\n--loud\n", bash.stdout + bash.stderr)
      declared = File.read(manifest)
      File.write(manifest, declared.sub("format: 1\n", "format: 2\n"))
      refused = attempt(asked, chdir: @project)
      File.write(manifest, declared)
      silent = refused.status.exit_code == 0 && refused.stderr.empty? &&
               refused.stdout == outside.stdout
      assert!(silent, refused.stdout + refused.stderr)
      puts "PASS: frappe __complete offers the shard's commands and their options in the " \
           "application and the built-ins outside it, bash completes demo:greet as one " \
           "word through the script, and a refused manifest is passed over in silence"
    end

    private def ran_shard_commands : Nil
      greet = [@frappe, "demo:greet"]
      loud = command(greet + ["Ada", "--loud"], chdir: @project, echo: false, timeout: 300.seconds)
      assert!(loud.stdout == "HELLO, ADA!\n", loud.stdout + loud.stderr)
      notes = command([@frappe, "demo:notes", "list"], chdir: @project, echo: false)
      assert!(notes.stdout == "Water the plants\nReturn the books\n", notes.stdout)
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
           "print what they print and exit with their status; " \
           "a missing argument is refused with the command's syntax before the application runs"
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
      assert!(usage.includes?("|demo:greet NAME [--loud]|demo:notes list|add TEXT"), usage)
      puts "PASS: the application starts with the recorder's insights in place of the stub, " \
           "and its usage lists the shard's commands"
    end
  end
end
