require "./project"
require "./publication"

module Caramel::Frappe
  # Adds a locale to an application, turning on internationalization the
  # first time.
  class LocaleGenerator
    CODE   = /\A[a-z]{2,3}(-[A-Z]{2}|-[A-Z][a-z]{3})?\z/
    CONFIG = "config/application.cr"

    CARAMEL_REQUIRE = %(require "caramel")
    VIEWS_REQUIRE   = %(require "../app/views/application_view")
    I18N_REQUIRE    = %(require "caramel/i18n")

    # Inserted before the views, which call `t`.
    I18N_LINES = %(require "../app/locales/*"\nCaramel.locales default: "en"\n\n)

    MISSING_ANCHORS = "config/application.cr needs exactly one require \"caramel\" " \
                      "and one require \"../app/views/application_view\"; " \
                      "add require \"caramel/i18n\", require \"../app/locales/*\" " \
                      "and Caramel.locales default: \"en\" by hand"

    ENGLISH = <<-CRYSTAL
      # app/locales/en.cr — the default locale; every key starts here.
      Caramel.locale "en", {
        common: {
          actions:         "Actions",
          view:            "View",
          edit:            "Edit",
          cancel:          "Cancel",
          check_fields:    "Please check the fields below.",
          newest:          "Showing the newest 100 records.",
          your_collection: "YOUR COLLECTION",
          fresh_start:     "A fresh start.",
          unspecified:     "Unspecified",
          option_true:     "True",
          option_false:    "False",
        },
        # Frappé resource messages
      }

      CRYSTAL

    # Creates app/locales/CODE.cr, and on first use app/locales/en.cr and the
    # i18n lines in config/application.cr. Returns the written paths.
    def generate(project : Project, code : String) : Array(String)
      raise Error.new("Use a locale code such as fr, pt-BR or zh-Hant") unless code.matches?(CODE)

      files = {} of String => String
      originals = {} of String => String
      if Dir.glob(File.join(project.root, "app/locales/*.cr")).empty?
        first_locale(project.root, files, originals)
      else
        later_locale(project.root, code)
      end
      files["app/locales/#{code}.cr"] = catalog(code) unless code == "en"
      Publication.publish(project, files, originals)
      files.keys.sort!
    end

    # Wires i18n into config/application.cr and starts the English catalog.
    private def first_locale(root : String,
                             files : Hash(String, String),
                             originals : Hash(String, String)) : Nil
      Publication.validate_path(root, CONFIG)
      original = File.read(File.join(root, CONFIG))
      lines = original.lines
      unless lines.count(CARAMEL_REQUIRE) == 1 && lines.count(VIEWS_REQUIRE) == 1
        raise Error.new(MISSING_ANCHORS)
      end
      originals[CONFIG] = original
      files[CONFIG] = wired(original)
      files["app/locales/en.cr"] = ENGLISH
    end

    private def wired(config : String) : String
      config
        .sub(/^#{Regex.escape(CARAMEL_REQUIRE)}$/m, "#{CARAMEL_REQUIRE}\n#{I18N_REQUIRE}")
        .sub(/^#{Regex.escape(VIEWS_REQUIRE)}$/m, "#{I18N_LINES}#{VIEWS_REQUIRE}")
    end

    private def later_locale(root : String, code : String) : Nil
      relative = "app/locales/#{code}.cr"
      if File.exists?(File.join(root, relative))
        raise Error.new("Locale #{code} already exists: #{relative}")
      end
      return if File.read(File.join(root, CONFIG)).lines.includes?(I18N_REQUIRE)

      raise Error.new("Run frappe make locale on an application " \
                      "whose config/application.cr requires caramel/i18n")
    end

    private def catalog(code : String) : String
      <<-CRYSTAL
        # Keys missing here use app/locales/en.cr; frappe translations lists them.
        # Set caramel.language to this language's own name.
        Caramel.locale "#{code}", {
          caramel: {language: "#{code}"},
        }

        CRYSTAL
    end
  end
end
