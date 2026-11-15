require "yaml"

module SweetTalk::Tool
  # `frappe sweettalk:make domain`: adds a SweetTalk domain (ADR 0030): the module with
  # its first context, its spec, on first use the require lines and `SweetTalk.boot` in
  # config/application.cr, and the SweetTalk skill for Claude Code when the application
  # has none. The first domain also excludes app/domain/ from Lint/UnusedArgument in the
  # application's .ameba.yml and adds the domain's two lines to its AGENTS.md. In a
  # multi-tenant application the domain names the tenant the routes' tenant block names
  # (ADR 0033).
  #
  # Whatever compiles this file requires the framework's `frappe/toolkit` first (ADR 0030).
  class DomainGenerator
    alias Kit = Caramel::Frappe::Toolkit
    alias Error = Caramel::Frappe::Error

    ROUTES = "config/routes.cr"
    SKILL  = ".claude/skills/sweettalk/SKILL.md"
    # The release's skill (ADR 0014, a generator's skill), compiled into the tool program.
    SKILL_TEXT = {{ read_file("#{__DIR__}/../../../templates/SKILL.md") }}

    SWEETTALK_REQUIRE = %(require "sweettalk")
    TENANCY_REQUIRE   = %(require "caramel/tenancy")
    JOBS_REQUIRE      = %(require "../app/jobs/*")
    DOMAIN_REQUIRE    = %(require "../app/domain/*")
    # Types every command, factory and service, called or not, so `frappe check`
    # sees their bodies (ADR 0030, bodies typed uncalled).
    BOOT = "SweetTalk.boot"

    # A name the domain or its first context may take: a class name, at most this long,
    # that neither the application nor the framework already uses.
    CLASS_NAME = /\A[A-Z][A-Za-z0-9]*\z/
    LONGEST    = 40
    RESERVED   = %w[
      App ApplicationAction ApplicationView Home Health Caramel SugarORM
      Object String Time Int32 Int64 Bool Float64
    ]
    # The tenant block that `frappe make tenancy` writes in config/routes.cr.
    TENANT_BLOCK = /^    tenant App::([A-Z][A-Za-z0-9]*), by: :[a-z][a-z0-9_]* do$/m

    DOMAINS   = "app/domain"
    LINT      = ".ameba.yml"
    LINT_RULE = "Lint/UnusedArgument"
    LINT_GLOB = "app/domain/**"
    LINT_ITEM = %(- "#{LINT_GLOB}")
    # What a rule set with no Lint/UnusedArgument section gains at its end.
    LINT_SECTION = <<-YAML

      # SweetTalk's whenever and compensate blocks are macro arguments: their
      # parameters name what the handler the macro writes receives, and a process
      # step's key: reads them outside the block (ADR 0030).
      Lint/UnusedArgument:
        Excluded:
          - "app/domain/**"

      YAML

    MISSING_ANCHORS = "config/application.cr needs exactly one require \"caramel\" " \
                      "and one require \"../app/jobs/*\"; add require \"sweettalk\" " \
                      "after the first and require \"../app/domain/*\" before the second by hand"
    NAMES = "Use class names such as Shop and Ordering for the domain and its first " \
            "context; the two must differ, and application and framework names are reserved"
    NO_MEANING = "Give the context a meaning on one line, " \
                 "as in --means=\"choosing teas and checking out\""
    CENTRAL_UNTENANTED = "--central is for multi-tenant applications; " \
                         "config/application.cr does not require caramel/tenancy"
    UNEDITABLE_LINT = ".ameba.yml is not in a shape frappe sweettalk:make domain can edit: " \
                      "add - \"app/domain/**\" to Excluded: under Lint/UnusedArgument: by " \
                      "hand, then make the domain again"

    GUIDE = "AGENTS.md"
    # What the first domain tells agents, each line after the one it follows in
    # the guide `frappe new` writes: where data lives, then where the domain does.
    GUIDE_LINES = [
      "Domain: app/domain/ in SweetTalk (add one with frappe sweettalk:make domain NAME " \
      "CONTEXT --means=TEXT)",
      "Domain rules: .claude/skills/sweettalk/SKILL.md",
    ]
    GUIDE_ANCHORS    = ["Data: ", "Domain: "]
    UNEDITABLE_GUIDE = "AGENTS.md is not in a shape frappe sweettalk:make domain can edit: " \
                       "add the lines Domain: app/domain/ in SweetTalk and Domain rules: " \
                       ".claude/skills/sweettalk/SKILL.md by hand, then make the domain again"

    # Writes app/domain/NAME.cr, spec/domain/NAME_spec.cr and, when missing, the skill in
    # the application at *root*; the first domain also edits .ameba.yml and AGENTS.md.
    # Returns the written paths.
    def generate(root : String, name : String, context : String,
                 means : String, *, central : Bool = false) : Array(String)
      validate(name, context, means)
      Kit.validate_path(root, Kit::CONFIG)
      original = File.read(File.join(root, Kit::CONFIG))
      lines = original.lines
      tenanted = lines.includes?(TENANCY_REQUIRE)
      raise Error.new(CENTRAL_UNTENANTED) if central && !tenanted
      tenant = tenanted ? tenant_model(root) : nil
      files = {} of String => String
      originals = {} of String => String
      wired = wired(original, lines)
      if wired != original
        originals[Kit::CONFIG] = original
        files[Kit::CONFIG] = wired
      end
      if rules = lint_edit(root)
        originals[LINT], files[LINT] = rules
      end
      if guide = guide_edit(root)
        originals[GUIDE], files[GUIDE] = guide
      end
      singular = name.underscore
      files["app/domain/#{singular}.cr"] = domain(name, context, means, tenant, central)
      files["spec/domain/#{singular}_spec.cr"] = spec(name, context, means)
      files[SKILL] = SKILL_TEXT if skill_missing?(root)
      Kit.publish(root, files, originals)
      files.keys.sort!
    end

    private def validate(name : String, context : String, means : String) : Nil
      valid = [name, context].all? do |word|
        word.matches?(CLASS_NAME) && word.size <= LONGEST && RESERVED.none?(word)
      end
      raise Error.new(NAMES) unless valid && name != context
      raise Error.new(NO_MEANING) if means.blank? || means.each_char.any?(&.control?)
    end

    private def first_domain?(root : String) : Bool
      directory = File.join(root, DOMAINS)
      !Dir.exists?(directory) || Dir.children(directory).none?(&.ends_with?(".cr"))
    end

    # The application's rule set before and after its first domain excludes
    # app/domain/ from Lint/UnusedArgument; nil for a later domain, and when
    # the rules exclude it already.
    private def lint_edit(root : String) : {String, String}?
      return unless first_domain?(root)
      Kit.validate_path(root, LINT)
      path = File.join(root, LINT)
      raise Error.new(UNEDITABLE_LINT) unless File.file?(path)
      rules = File.read(path)
      {rules, excluding(rules)} unless excluded?(rules)
    end

    # The application's AGENTS.md before and after its first domain adds the
    # lines that say where the domain and its rules are; nil for a later domain,
    # and when the guide has a line for each already. A missing line goes after
    # the last line that says where data or the domain lives, and every other
    # line stays as it is.
    private def guide_edit(root : String) : {String, String}?
      return unless first_domain?(root)
      Kit.validate_path(root, GUIDE)
      path = File.join(root, GUIDE)
      raise Error.new(UNEDITABLE_GUIDE) unless File.file?(path)
      guide = File.read(path)
      lines = guide.lines(chomp: false)
      missing = GUIDE_LINES.reject do |line|
        label = line[/\A[^:]+: /]
        lines.any?(&.starts_with?(label))
      end
      return if missing.empty?
      anchor = lines.rindex { |line| GUIDE_ANCHORS.any? { |start| line.starts_with?(start) } }
      raise Error.new(UNEDITABLE_GUIDE) unless anchor
      lines[anchor] += "\n" unless lines[anchor].ends_with?('\n')
      lines.insert(anchor + 1, missing.join { |line| "#{line}\n" })
      {guide, lines.join}
    end

    # The rules by name, as YAML reads them.
    private def rules_by_name(rules : String) : Hash(YAML::Any, YAML::Any)
      YAML.parse(rules).as_h? || raise Error.new(UNEDITABLE_LINT)
    rescue YAML::ParseException
      raise Error.new(UNEDITABLE_LINT)
    end

    # Whether *rules* already exclude app/domain/ from Lint/UnusedArgument,
    # in whatever layout they write the list.
    private def excluded?(rules : String) : Bool
      rule = rules_by_name(rules)[YAML::Any.new(LINT_RULE)]?.try(&.as_h?) || return false
      globs = rule[YAML::Any.new("Excluded")]?.try(&.as_a?) || return false
      globs.any? { |glob| glob.as_s? == LINT_GLOB }
    end

    # *rules* with app/domain/ excluded from Lint/UnusedArgument: one more
    # item in the section they hold, or a new section at their end. Every
    # other line stays as it is, and the last one gains the newline it lacks.
    private def excluding(rules : String) : String
      rules += "\n" unless rules.ends_with?('\n')
      declared = rules_by_name(rules).has_key?(YAML::Any.new(LINT_RULE))
      edited = declared ? listed(rules) : rules + LINT_SECTION
      raise Error.new(UNEDITABLE_LINT) unless excluded?(edited)
      edited
    end

    # *rules*, which hold a Lint/UnusedArgument section, with the item in its
    # Excluded: list, or with that list when the section has none.
    private def listed(rules : String) : String
      lines = rules.lines(chomp: false)
      head = lines.index { |line| line.chomp == "#{LINT_RULE}:" }
      raise Error.new(UNEDITABLE_LINT) unless head
      rest = lines[(head + 1)..]
      section = rest.first(rest.index(&.matches?(/^\S/)) || rest.size)
      list = section.index(&.matches?(/^\s+Excluded:/))
      offset, addition = list ? item(section, list) : {0, "  Excluded:\n    #{LINT_ITEM}\n"}
      lines.insert(head + 1 + offset, addition)
      lines.join
    end

    # Where the item goes among the *section*'s lines, and how it reads: after
    # the last item of the Excluded: list at *list*, indented as that item is.
    private def item(section : Array(String), list : Int32) : {Int32, String}
      opening = section[list]
      raise Error.new(UNEDITABLE_LINT) unless opening.matches?(/^\s+Excluded:\s*$/)
      items = section[(list + 1)..].take_while(&.matches?(/^\s+- /))
      indent = items.last?.try(&.[/^\s+/]) || "#{opening[/^\s+/]}  "
      {list + 1 + items.size, "#{indent}#{LINT_ITEM}\n"}
    end

    # An existing skill, edited or not, is the application's own, and a
    # symlink on its path is left alone too: the toolkit refuses to follow it.
    private def skill_missing?(root : String) : Bool
      Kit.validate_path(root, SKILL)
      !File.info?(File.join(root, SKILL), follow_symlinks: false)
    rescue Error
      false
    end

    # The tenant block's model, as `frappe make resource` reads it.
    private def tenant_model(root : String) : String
      routes = File.read(File.join(root, ROUTES))
      model = routes.match(TENANT_BLOCK).try(&.[1])
      raise Error.new("config/routes.cr has no tenant App::Model, by: :field do line") unless model
      model
    end

    # Adds whichever of the two require lines and the boot line is missing.
    private def wired(config : String, lines : Array(String)) : String
      present = [SWEETTALK_REQUIRE, DOMAIN_REQUIRE, BOOT].all? { |line| lines.includes?(line) }
      return config if present
      unless lines.count(Kit::CARAMEL_REQUIRE) == 1 && lines.count(JOBS_REQUIRE) == 1
        raise Error.new(MISSING_ANCHORS)
      end
      config = Kit.required(config, SWEETTALK_REQUIRE)
      unless lines.includes?(DOMAIN_REQUIRE)
        config = config.sub(/^#{Regex.escape(JOBS_REQUIRE)}$/m,
          "#{DOMAIN_REQUIRE}\n#{JOBS_REQUIRE}")
      end
      unless lines.includes?(BOOT)
        config = config.sub(/^#{Regex.escape(DOMAIN_REQUIRE)}$/m,
          "#{DOMAIN_REQUIRE}\n#{BOOT}")
      end
      config
    end

    private def domain(name : String, context : String, means : String,
                       tenant : String?, central : Bool) : String
      tenant_line = tenant ? "  tenant App::#{tenant}\n" : ""
      opening = central ? "#{context}, central: true" : context
      <<-CRYSTAL
        # The #{name} domain, in SweetTalk (ADR 0030). Its words, such as
        # context, value, aggregate, event and whenever, exist only inside this module.
        module App::#{name}
          include SweetTalk
        #{tenant_line}
          context #{opening}, means: #{means.inspect} do
          end
        end

        CRYSTAL
    end

    private def spec(name : String, context : String, means : String) : String
      <<-CRYSTAL
        require "../spec_helper"

        describe App::#{name} do
          it "gives the #{context} context its meaning in the glossary" do
            term = SweetTalk.glossary.find do |entry|
              entry.kind == "context" && entry.name == #{context.inspect}
            end
            term.try(&.means).should eq(#{means.inspect})
          end
        end

        CRYSTAL
    end
  end
end
