require "./project"
require "./publication"
require "./resource_generator"

module Caramel::Frappe
  # Adds a SweetTalk domain (ADRs 0030 and 0031): the module with its first
  # context, its spec, on first use the require lines and `SweetTalk.boot` in
  # config/application.cr, and the SweetTalk skill for Claude Code when the
  # application has none. In a multi-tenant application the domain names the
  # tenant the routes' tenant block names (ADR 0033).
  class DomainGenerator
    CONFIG = "config/application.cr"
    ROUTES = "config/routes.cr"
    SKILL  = ".claude/skills/sweettalk/SKILL.md"
    # The release's skill (ADR 0026 decision 8), compiled into Frappé.
    SKILL_TEXT = {{ read_file("#{__DIR__}/../../templates/skills/sweettalk/SKILL.md") }}

    CARAMEL_REQUIRE    = %(require "caramel")
    SWEET_TALK_REQUIRE = %(require "caramel/sweet_talk")
    TENANCY_REQUIRE    = %(require "caramel/tenancy")
    JOBS_REQUIRE       = %(require "../app/jobs/*")
    DOMAIN_REQUIRE     = %(require "../app/domain/*")
    # Types every command, factory and service, called or not, so `frappe check`
    # sees their bodies (ADR 0031 decision 10).
    BOOT = "SweetTalk.boot"

    MISSING_ANCHORS = "config/application.cr needs exactly one require \"caramel\" " \
                      "and one require \"../app/jobs/*\"; add require \"caramel/sweet_talk\" " \
                      "after the first and require \"../app/domain/*\" before the second by hand"
    NAMES = "Use class names such as Shop and Ordering for the domain and its first " \
            "context; the two must differ, and application and framework names are reserved"
    NO_MEANING = "Give the context a meaning on one line, " \
                 "as in --means=\"choosing teas and checking out\""
    CENTRAL_UNTENANTED = "--central is for multi-tenant applications; " \
                         "config/application.cr does not require caramel/tenancy"

    # Writes app/domain/NAME.cr, spec/domain/NAME_spec.cr and, when missing,
    # the skill. Returns the written paths.
    def generate(project : Project, name : String, context : String,
                 means : String, *, central : Bool = false) : Array(String)
      validate(name, context, means)
      root = project.root
      Publication.validate_path(root, CONFIG)
      original = File.read(File.join(root, CONFIG))
      lines = original.lines
      tenanted = lines.includes?(TENANCY_REQUIRE)
      raise Error.new(CENTRAL_UNTENANTED) if central && !tenanted
      tenant = tenanted ? tenant_model(root) : nil
      files = {} of String => String
      originals = {} of String => String
      wired = wired(original, lines)
      if wired != original
        originals[CONFIG] = original
        files[CONFIG] = wired
      end
      singular = name.underscore
      files["app/domain/#{singular}.cr"] = domain(name, context, means, tenant, central)
      files["spec/domain/#{singular}_spec.cr"] = spec(name, context, means)
      files[SKILL] = SKILL_TEXT if skill_missing?(root)
      Publication.publish(project, files, originals)
      files.keys.sort!
    end

    private def validate(name : String, context : String, means : String) : Nil
      valid = [name, context].all? do |word|
        word.matches?(ResourceGenerator::MODEL_NAME) && word.size <= 40 &&
          ResourceGenerator::RESERVED_NAMES.none?(word)
      end
      raise Error.new(NAMES) unless valid && name != context
      raise Error.new(NO_MEANING) if means.blank? || means.each_char.any?(&.control?)
    end

    # An existing skill, edited or not, is the application's own, and a
    # symlink on its path is left alone too: Publication refuses to follow it.
    private def skill_missing?(root : String) : Bool
      Publication.validate_path(root, SKILL)
      !File.info?(File.join(root, SKILL), follow_symlinks: false)
    rescue Error
      false
    end

    # The tenant block's model, as `frappe make resource` reads it.
    private def tenant_model(root : String) : String
      routes = File.read(File.join(root, ROUTES))
      model = routes.match(ResourceGenerator::TENANT_BLOCK).try(&.[1])
      raise Error.new("config/routes.cr has no tenant App::Model, by: :field do line") unless model
      model
    end

    # Adds whichever of the two require lines and the boot line is missing.
    private def wired(config : String, lines : Array(String)) : String
      present = [SWEET_TALK_REQUIRE, DOMAIN_REQUIRE, BOOT].all? { |line| lines.includes?(line) }
      return config if present
      unless lines.count(CARAMEL_REQUIRE) == 1 && lines.count(JOBS_REQUIRE) == 1
        raise Error.new(MISSING_ANCHORS)
      end
      unless lines.includes?(SWEET_TALK_REQUIRE)
        config = config.sub(/^#{Regex.escape(CARAMEL_REQUIRE)}$/m,
          "#{CARAMEL_REQUIRE}\n#{SWEET_TALK_REQUIRE}")
      end
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
        # The #{name} domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
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
