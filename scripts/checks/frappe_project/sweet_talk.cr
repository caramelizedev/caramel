module Caramel::Checks
  # The sweettalk shard on the generated application, which installs the published
  # shard beside the published framework (LatteFixture#add_sweettalk): the commands its
  # frappe.yml declares are absent until then, its tool commands run before the
  # application requires it, and its application commands print what the application's
  # domain declares.
  class FrappeProject < ProjectFixture
    # What only Frappé's own code for SweetTalk's commands would hold.
    SWEETTALK_MARKERS = ["SweetTalk", "sweettalk:"]
    SWEETTALK_HELP    = <<-TEXT
      sweettalk:words         Look up SweetTalk's vocabulary
      sweettalk:requirements  List the requirements the domain assures
      sweettalk:glossary      Print the domain's glossary
      sweettalk:contexts      Print the domain's context map
      sweettalk:make          Generate code: domain
      TEXT
    UNKNOWN_WORD = <<-MRDP
      ERR USAGE at frappe sweettalk:words
      MSG: unknown word valeu; nearest: value
      SYNTAX: frappe sweettalk:words [WORD] [--json]
      SUGGEST: value\n
      MRDP
    # A program as an application writes it: the framework and the shard by their names.
    MONEY_PROBE = <<-CRYSTAL
      require "caramel"
      require "sweettalk/money"

      module Probe
        include SweetTalk

        context Till, means: "the money a shop takes" do
          currencies %w[USD EUR], means: "a currency the till takes"
        end
      end

      SweetTalk.boot\n
      CRYSTAL

    # Adds the shard to the application, which has no domain yet and does not require it.
    def sweet_talk_shard : Nil
      without_sweet_talk
      add_sweettalk(@project, migrate: false)
      listed_sweet_talk
      sweet_talk_words
      sweet_talk_by_name
    end

    # Frappé without the shard: no command of it in the application or outside it, an
    # unknown command when one is asked for, and nothing of them in the binary.
    private def without_sweet_talk : Nil
      [@project, @projects].each do |directory|
        listed = command([@frappe, "help"], chdir: directory, echo: false).stdout +
                 command([@frappe, "agent-manifest"], chdir: directory, echo: false).stdout
        assert!(!listed.downcase.includes?("sweettalk"), listed)
        asked = attempt([@frappe, "sweettalk:words"], chdir: directory)
        unknown = asked.status.exit_code == 1 && asked.stdout.empty? &&
                  asked.stderr.includes?("unknown command sweettalk:words")
        assert!(unknown, asked.stdout + asked.stderr)
      end
      held = File.read(@frappe)
      SWEETTALK_MARKERS.each { |marker| assert!(!held.includes?(marker), "frappe holds #{marker}") }
      puts "PASS: in an application without the sweettalk shard, and outside one, Frappé " \
           "lists no SweetTalk command, answers frappe sweettalk:words as an unknown " \
           "command, and its binary names SweetTalk nowhere"
    end

    private def listed_sweet_talk : Nil
      help = command([@frappe, "help"], chdir: @project, echo: false)
      rows = SWEETTALK_HELP.lines.map(&.split(/\s{2,}/))
      listed = help.stdout.includes?("\nSWEETTALK\n") && rows.all? do |row|
        help.stdout.lines.any? { |line| line.strip.split(/\s{2,}/) == row }
      end
      assert!(listed && help.stderr.empty?, help.stdout + help.stderr)
      manifest = command([@frappe, "agent-manifest"], chdir: @project, echo: false).stdout
      ["frappe sweettalk:words [WORD] [--json]  # ", "frappe sweettalk:requirements [ID]  # ",
       "frappe sweettalk:glossary [--json]  # ", "frappe sweettalk:contexts [--mermaid]  # ",
       "frappe sweettalk:make domain NAME CONTEXT --means=TEXT [--central]  # "].each do |line|
        assert!(manifest.includes?(line), manifest)
      end
      outside = command([@frappe, "help"], chdir: @projects, echo: false).stdout
      assert!(!outside.downcase.includes?("sweettalk"), outside)
      puts "PASS: with the published shard installed beside the framework, frappe help " \
           "and frappe agent-manifest list the five frappe sweettalk: commands in the " \
           "application, and none outside it"
    end

    # The words, from the shard's sources under lib/, before the application requires it.
    private def sweet_talk_words : Nil
      words = [@frappe, "sweettalk:words"]
      all = command(words, chdir: @project, echo: false, timeout: 300.seconds)
      heading = "SweetTalk words in Caramel #{Caramel::VERSION}: "
      listed = all.stdout.starts_with?(heading) &&
               all.stdout.includes?("\nnoun: declares a thing the glossary lists\n")
      assert!(listed, all.stdout + all.stderr)
      value = command(words + ["value"], chdir: @project, echo: false).stdout
      guide = "  Guide: #{Caramel::WEBSITE}/docs/#{Caramel::VERSION}/sweettalk/index.md#"
      one = value.starts_with?("value (noun)\n") && value.includes?("  value NAME, TYPE") &&
            value.includes?(guide) && value.includes?("    at_least:  ")
      assert!(one, value)
      printed = command(words + ["value", "--json"], chdir: @project, echo: false).stdout
      document = JSON.parse(printed)
      source = document["forms"][0]["source"].as_s
      assert!(source.starts_with?("lib/sweettalk/src/sweettalk/"), source)
      every = JSON.parse(command(words + ["--json"], chdir: @project, echo: false).stdout)
      assert!(every["version"] == Caramel::VERSION, every["version"].to_s)
      assert!(every["words"].as_a.map(&.["word"].as_s).includes?("whenever"))
      unknown = attempt(words + ["valeu"], chdir: @project)
      refused = unknown.status.exit_code == 1 && unknown.stdout.empty? &&
                unknown.stderr == UNKNOWN_WORD
      assert!(refused, unknown.stdout + unknown.stderr)
      application = File.read(File.join(@project, "config/application.cr"))
      assert!(!application.includes?("sweettalk"), application)
      puts "PASS: frappe sweettalk:words builds the shard's tool program in an application " \
           "that does not require the shard, lists every word, prints one with its guide " \
           "section and its source under lib/sweettalk, the same as JSON, and refuses an " \
           "unknown word with the nearest one"
    end

    # `sweettalk/money` reaches the framework's decimal codec by the framework's shard
    # name, which only a program with lib/caramel resolves.
    private def sweet_talk_by_name : Nil
      probe = File.join(@project, "sweettalk_probe.cr")
      File.write(probe, MONEY_PROBE)
      command([File.join(@repo, "scripts/crystal"), "build", probe, "--no-codegen"],
        chdir: @project, timeout: 300.seconds)
      File.delete(probe)
      puts "PASS: a program that requires caramel and sweettalk/money by their shard " \
           "names type-checks in the application"
    end

    # The application's own commands, once it requires the shard and declares a domain.
    def sweet_talk_commands : Nil
      sweet_talk_glossary
      sweet_talk_contexts
      sweet_talk_requirements
    end

    private def sweet_talk_glossary : Nil
      glossary = [@frappe, "sweettalk:glossary"]
      markdown = command(glossary, chdir: @project, echo: false, timeout: 300.seconds).stdout
      section = "\n## Ordering (context)\n\nchoosing teas and checking out\n"
      order = "| Order | aggregate | one customer's order | " \
              "states: open, placed; moves: open >> placed |\n"
      printed = markdown.starts_with?("# Glossary\n") && markdown.includes?(section) &&
                markdown.includes?(order)
      assert!(printed, markdown)
      document = JSON.parse(command(glossary + ["--json"], chdir: @project, echo: false).stdout)
      contexts = document["terms"].as_a.select(&.["kind"].==("context")).map(&.["name"].as_s)
      assert!(contexts.sort == %w[Ordering Shelf], contexts.inspect)
      assert!(!document["map"].as_a?.nil?, document.to_json)
      assert!(!File.exists?(File.join(@project, ".caramel/glossary.json")))
      puts "PASS: frappe sweettalk:glossary prints the application's glossary as Markdown " \
           "and --json the document, and keeps no copy of it"
    end

    private def sweet_talk_contexts : Nil
      contexts = [@frappe, "sweettalk:contexts"]
      text = command(contexts, chdir: @project, echo: false).stdout
      assert!(text.lines.sort! == %w[Ordering Shelf], text)
      mermaid = command(contexts + ["--mermaid"], chdir: @project, echo: false).stdout
      drawn = mermaid.starts_with?("flowchart LR\n") && mermaid.includes?("  Ordering\n")
      assert!(drawn, mermaid)
      extra = attempt(contexts + ["--json"], chdir: @project)
      refused = extra.status.exit_code == 1 && extra.stderr.includes?("unknown option --json")
      assert!(refused, extra.stdout + extra.stderr)
      puts "PASS: frappe sweettalk:contexts prints the context map as text and --mermaid " \
           "as a flowchart, and an option it lacks is refused before the application runs"
    end

    private def sweet_talk_requirements : Nil
      requirements = [@frappe, "sweettalk:requirements"]
      none = command(requirements, chdir: @project, echo: false)
      assert!(none.stdout == "This application declares no requirements.\n", none.stdout)
      missing = attempt(requirements + ["AC-1"], chdir: @project)
      refused = missing.status.exit_code == 1 && missing.stdout.empty? &&
                missing.stderr == "AC-1 is not a requirement; requirements: none\n"
      assert!(refused, missing.stdout + missing.stderr)
      puts "PASS: frappe sweettalk:requirements lists the application's requirements and " \
           "exits 1 for an id it does not declare"
    end
  end
end
