require "./keys"
require "./plural"

module Caramel::I18n
  # Every catalog `Caramel.locale` declared, in order:
  # `{code, messages, plural family, filename}`. Only macros read it.
  CATALOGS = [] of Nil

  # What `Caramel.locales` derived from CATALOGS, for the macros that write
  # the code. Only macros read it.
  COMPILED = {} of Nil => Nil

  # A language tag: a language, then an optional region or script.
  CODE = /\A[a-z]{2,3}(-[A-Z]{2}|-[A-Z][a-z]{3})?\z/

  # The keys of a plural message: CLDR categories, and `=N` for exact counts.
  CATEGORIES = %w[zero one two few many other]
  EXACT      = /\A=\d+\z/

  # The directives a `caramel.time.formats` pattern may use.
  DIRECTIVES = %w[%Y %m %-m %d %-d %H %-H %I %-I %M %S %p %B %b %A %a %%]

  # Caramel's own messages: the key under `caramel:`, then the module and
  # method it translates and the placeholders that method passes.
  FRAMEWORK_MESSAGES = [
    {"errors.required", "::Caramel::Wording", "required", %w[]},
    {"errors.required", "::SugarORM::Wording", "required", %w[]},
    {"errors.must_be_file", "::Caramel::Wording", "must_be_file", %w[]},
    {"errors.json_type", "::Caramel::Wording", "json_type", %w[type]},
    {"errors.invalid_value", "::Caramel::Wording", "invalid_value", %w[type]},
    {"errors.at_least", "::Caramel::Wording", "at_least", %w[min]},
    {"errors.at_least", "::SugarORM::Wording", "at_least", %w[min]},
    {"errors.at_least_characters", "::Caramel::Wording", "at_least_characters", %w[min]},
    {"errors.at_most", "::Caramel::Wording", "at_most", %w[max]},
    {"errors.at_most", "::SugarORM::Wording", "at_most", %w[max]},
    {"errors.at_most_characters", "::Caramel::Wording", "at_most_characters", %w[max]},
    {"errors.at_least_items", "::Caramel::Wording", "at_least_items", %w[min]},
    {"errors.at_most_items", "::Caramel::Wording", "at_most_items", %w[max]},
    {"errors.duplicate_item", "::Caramel::Wording", "duplicate_item", %w[]},
    {"errors.duplicate_field", "::Caramel::Wording", "duplicate_field", %w[name]},
    {"errors.unknown_field", "::Caramel::Wording", "unknown_field", %w[name]},
    {"errors.expected_json_object", "::Caramel::Wording", "expected_json_object", %w[]},
    {"errors.url", "::Caramel::Wording", "url", %w[]},
    {"errors.blank", "::SugarORM::Wording", "blank", %w[]},
    {"errors.greater_than", "::SugarORM::Wording", "greater_than", %w[than]},
    {"errors.less_than", "::SugarORM::Wording", "less_than", %w[than]},
    {"errors.too_short", "::SugarORM::Wording", "too_short", %w[min]},
    {"errors.too_long", "::SugarORM::Wording", "too_long", %w[max]},
    {"errors.invalid_format", "::SugarORM::Wording", "invalid_format", %w[]},
    {"errors.invalid", "::SugarORM::Wording", "invalid", %w[]},
    {"errors.taken", "::SugarORM::Wording", "taken", %w[]},
    {"errors.record_gone", "::SugarORM::Wording", "record_gone", %w[]},
    {"pages.check_request", "::Caramel::Wording", "check_request", %w[]},
    {"pages.not_found", "::Caramel::Wording", "not_found", %w[]},
    {"pages.expired_form", "::Caramel::Wording", "expired_form", %w[]},
  ]

  # The formatting data of the `caramel:` section that English supplies when
  # neither a locale nor the default locale does.
  ENGLISH = {
    language: "English",
    number:   {separator: ".", delimiter: ","},
    time:     {
      months: %w[
        January February March April May June
        July August September October November December
      ],
      abbr_months: %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec],
      days:        %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday],
      abbr_days:   %w[Sun Mon Tue Wed Thu Fri Sat],
      am:          "AM",
      pm:          "PM",
      formats:     {
        date:       "%B %-d, %Y",
        time:       "%-I:%M %p",
        datetime:   "%B %-d, %Y %-I:%M %p",
        short_date: "%b %-d",
      },
    },
  }

  # The `caramel:` keys that hold text, other than time formats and the
  # framework messages, and the names each time list needs.
  FRAMEWORK_TEXTS = %w[
    caramel.language caramel.number.separator caramel.number.delimiter
    caramel.time.am caramel.time.pm
  ]
  TIME_LISTS = {
    "caramel.time.months"      => 12,
    "caramel.time.abbr_months" => 12,
    "caramel.time.days"        => 7,
    "caramel.time.abbr_days"   => 7,
  }
  FRAMEWORK_GROUPS = %w[
    caramel caramel.number caramel.time caramel.time.formats caramel.errors caramel.pages
  ]
end

module Caramel
  # Declares one locale's catalog (ADR 0024), conventionally in
  # `app/locales/CODE.cr`:
  #
  # ```
  # Caramel.locale "fr", {
  #   home:  {title: "Bienvenue", greeting: "Bonjour, %{name} !"},
  #   books: {count: {one: "%{count} livre", many: "%{count} de livres", other: "%{count} livres"}},
  # }
  # ```
  #
  # A value is a message, a plural (a named tuple whose keys are all CLDR
  # categories or `=N`) or a group of further keys; so a group's keys cannot
  # all be category names. `%{name}` is a placeholder. The reserved
  # `caramel:` section translates Caramel's own messages and supplies number
  # and time formats. A language Caramel has no plural rules for names one
  # that shares them: `plural: "en"`. `Caramel.locales` checks and compiles
  # every catalog.
  macro locale(code, messages, plural = nil)
    {% at = "\n  --> #{code.filename.id}:#{code.line_number}:#{code.column_number}" %}
    {% unless code.is_a?(StringLiteral) && code =~ ::Caramel::I18n::CODE %}
      {% code.raise "locale code '#{code.id}' is not a language tag such as fr, pt-BR or " +
                    "zh-Hant" + at + "\nRemediation: write a lowercase language code, " +
                    "optionally followed by an uppercase region or a capitalized script." %}
    {% end %}
    {% unless messages.is_a?(NamedTupleLiteral) %}
      {% messages.raise "Caramel.locale #{code} needs its messages as a named tuple literal" +
                        at + "\nRemediation: write them as {home: {title: \"…\"}}." %}
    {% end %}
    {% languages = ::Caramel::I18n::LANGUAGES %}
    {% source = plural || code %}
    {% family = languages[source.id.stringify] || languages[source.id.stringify.split("-")[0]] %}
    {% if plural && !plural.is_a?(StringLiteral) %}
      {% family = nil %}
    {% end %}
    {% unless family %}
      {% node = plural || code %}
      {% node.raise "no plural rules for '#{source.id}'" +
                    "\n  --> #{node.filename.id}:#{node.line_number}:#{node.column_number}" +
                    "\nRemediation: add `plural: \"en\"` naming a language " +
                    "with the same plural rules." %}
    {% end %}
    {% ::Caramel::I18n::CATALOGS << {code, messages, family, @caller.first.filename} %}
  end

  # Compiles every catalog `Caramel.locale` declared (ADR 0024). Call it
  # once, after the catalogs:
  #
  # ```
  # require "../app/locales/*"
  # Caramel.locales default: "en", prefix: false
  # ```
  #
  # Every locale's keys must be the default locale's, with the same
  # placeholders and the plural forms its language needs; a missing key
  # uses the default locale's text, and the application's `translations`
  # command lists it. It defines `Caramel::Locale`, `Caramel::Messages`
  # (what `t` returns) and the translations of Caramel's own messages.
  # `prefix: true` serves every locale but the default under `/CODE/…`.
  macro locales(default, prefix = false)
    {% catalogs = ::Caramel::I18n::CATALOGS %}
    {% here = "\n  --> #{default.filename.id}:#{default.line_number}:" +
              "#{default.column_number}" %}
    {% if ::Caramel.has_constant?("Locale") %}
      {% default.raise "Caramel.locales is called twice" + here +
                       "\nRemediation: call it once, after every Caramel.locale catalog." %}
    {% end %}
    {% if catalogs.empty? %}
      {% default.raise "Caramel.locales needs a Caramel.locale catalog before it" + here +
                       "\nRemediation: require \"../app/locales/*\" before Caramel.locales." %}
    {% end %}
    {% unless prefix.is_a?(BoolLiteral) %}
      {% prefix.raise "Caramel.locales prefix: must be true or false, got #{prefix}" + here +
                      "\nRemediation: write prefix: true or prefix: false." %}
    {% end %}
    {% codes = [] of StringLiteral %}
    {% for catalog in catalogs %}
      {% code = catalog[0] %}
      {% if codes.includes?(code) %}
        {% code.raise "locale '#{code.id}' is declared twice" +
                      "\n  --> #{code.filename.id}:#{code.line_number}:#{code.column_number}" +
                      "\nRemediation: keep one Caramel.locale #{code} catalog." %}
      {% end %}
      {% codes << code %}
    {% end %}
    {% unless default.is_a?(StringLiteral) && codes.includes?(default) %}
      {% default.raise "Caramel.locales default: '#{default.id}' names no declared locale" +
                       here + "\nRemediation: name one of #{codes.join(", ").id}." %}
    {% end %}

    {% locales = [] of Nil %}
    {% for catalog in catalogs %}
      {% code = catalog[0] %}
      # Flatten breadth-first: a group's entry comes before its children's.
      {% entries = {} of String => Nil %}
      {% work = [{"", catalog[1]}] %}
      {% for pair in work %}
        {% for key, value in pair[1] %}
          {% name = key.stringify %}
          {% path = pair[0].empty? ? name : pair[0] + "." + name %}
          {% section = path == "caramel" || path.starts_with?("caramel.") %}
          {% at = "\n  --> #{value.filename.id}:#{value.line_number}:#{value.column_number}" %}
          {% unless name =~ ::Caramel::I18n::KEY && !name.includes?("__") %}
            {% value.raise "catalog key '#{path.id}' is not a lowercase identifier" + at +
                           "\nRemediation: start it with a letter and use only lowercase " +
                           "letters, digits and single underscores." %}
          {% end %}
          {% if ::Caramel::I18n::RESERVED_KEYS.includes?(name) ||
                  ::Caramel::I18n::KEY_ONLY_RESERVED.includes?(name) %}
            {% value.raise "catalog key '#{path.id}' is reserved by Crystal or Caramel" + at +
                           "\nRemediation: rename the key." %}
          {% end %}
          {% if value.is_a?(StringInterpolation) %}
            {% value.raise "catalog text is literal: '#{path.id}' interpolates Crystal; " +
                           "write %{name} placeholders" + at +
                           "\nRemediation: replace each \#{…} with a %{name} placeholder " +
                           "and pass name: when you call the message." %}
          {% end %}
          {% forms = value.is_a?(NamedTupleLiteral) && !section ? value.keys : [] of MacroId %}
          {% forms = forms.map(&.stringify) %}
          {% uncounted = forms.reject { |form| ::Caramel::I18n::CATEGORIES.includes?(form) } %}
          {% plural = !forms.empty? && uncounted.all? { |form| form =~ ::Caramel::I18n::EXACT } %}
          {% if value.is_a?(StringLiteral) %}
            {% entries[path] = {"message", value} %}
          {% elsif plural %}
            {% entries[path] = {"plural", value} %}
            {% for form, text in value %}
              {% if text.is_a?(StringInterpolation) %}
                {% text.raise "catalog text is literal: '#{path.id}' interpolates Crystal; " +
                              "write %{name} placeholders" +
                              "\n  --> #{text.filename.id}:#{text.line_number}:" +
                              "#{text.column_number}" +
                              "\nRemediation: replace each \#{…} with a %{name} placeholder." %}
              {% end %}
              {% unless text.is_a?(StringLiteral) %}
                {% text.raise "plural '#{path.id}' form #{form} must be text" +
                              "\n  --> #{text.filename.id}:#{text.line_number}:" +
                              "#{text.column_number}" +
                              "\nRemediation: write each form as a string literal." %}
              {% end %}
            {% end %}
          {% elsif value.is_a?(NamedTupleLiteral) %}
            {% entries[path] = {"group", value} %}
            {% work << {path, value} %}
          {% elsif value.is_a?(ArrayLiteral) && section %}
            {% entries[path] = {"list", value} %}
          {% else %}
            {% value.raise "catalog value '#{path.id}' is not text, a plural or a group" + at +
                           "\nRemediation: write a string literal, or a named tuple of them." %}
          {% end %}
        {% end %}
      {% end %}

      # Parse each text into literal parts and %{name} placeholders.
      {% texts = {} of String => Nil %}
      {% sources = [] of Nil %}
      {% for path, entry in entries %}
        {% messages = path.starts_with?("caramel.errors.") ||
                      path.starts_with?("caramel.pages.") ||
                      !path.starts_with?("caramel.") %}
        {% if entry[0] == "message" && messages %}
          {% sources << {path, entry[1], path.starts_with?("caramel.")} %}
        {% elsif entry[0] == "plural" %}
          {% for form, text in entry[1] %}
            {% sources << {path + "|" + form.stringify, text, false} %}
          {% end %}
        {% end %}
      {% end %}
      {% for source in sources %}
        {% text = source[1] %}
        {% at = "\n  --> #{text.filename.id}:#{text.line_number}:#{text.column_number}" %}
        {% parts = [] of Nil %}
        {% names = [] of StringLiteral %}
        {% for piece, index in text.split("%{") %}
          {% if index == 0 %}
            {% unless piece.empty? %}
              {% parts << {false, piece} %}
            {% end %}
          {% else %}
            {% segments = piece.split("}") %}
            {% name = segments[0] %}
            {% valid = piece.includes?("}") && name =~ ::Caramel::I18n::KEY &&
                       !name.includes?("__") &&
                       (source[2] || !::Caramel::I18n::RESERVED_KEYS.includes?(name)) %}
            {% unless valid %}
              {% text.raise "catalog placeholder '%{#{name.id}}' in " +
                            "'#{source[0].split("|")[0].id}' is not a lowercase identifier" +
                            at + "\nRemediation: name each placeholder like %{name}; " +
                            "text cannot hold a literal %{." %}
            {% end %}
            {% parts << {true, name} %}
            {% names << name %}
            {% rest = segments[1..-1].join("}") %}
            {% unless rest.empty? %}
              {% parts << {false, rest} %}
            {% end %}
          {% end %}
        {% end %}
        {% texts[source[0]] = {parts, names.uniq.sort} %}
      {% end %}

      # Each message's and plural's placeholders: a plural's `count` is its
      # selector, and its other placeholders are those of all its forms.
      {% placeholders = {} of String => Nil %}
      {% for path, entry in entries %}
        {% if entry[0] == "message" && texts[path] %}
          {% placeholders[path] = texts[path][1] %}
        {% elsif entry[0] == "plural" %}
          {% union = [] of StringLiteral %}
          {% for form, text in entry[1] %}
            {% union = union + texts[path + "|" + form.stringify][1] %}
          {% end %}
          {% placeholders[path] = union.uniq.sort.reject { |name| name == "count" } %}
        {% end %}
      {% end %}
      {% language = code.split("-")[0] %}
      {% locales << {
           "code"         => code,
           "member"       => code.downcase.split("-").map(&.capitalize).join(""),
           "language"     => language,
           "family"       => catalog[2],
           "file"         => catalog[3],
           "entries"      => entries,
           "texts"        => texts,
           "placeholders" => placeholders,
         } %}
    {% end %}

    {% base = locales.find { |locale| locale["code"] == default } %}
    {% english = ::Caramel::I18n::ENGLISH %}
    # The time formats: English's, then those the default locale adds.
    {% formats = english[:time][:formats].keys.map(&.stringify) %}
    {% for path, entry in base["entries"] %}
      {% if path.starts_with?("caramel.time.formats.") %}
        {% format = path.split(".").last %}
        {% unless formats.includes?(format) %}
          {% formats << format %}
        {% end %}
      {% end %}
    {% end %}
    {% framework_keys = {} of String => Nil %}
    {% for message in ::Caramel::I18n::FRAMEWORK_MESSAGES %}
      {% framework_keys["caramel." + message[0]] = message[3] %}
    {% end %}

    # Check each locale against the default locale and the framework keys.
    {% for locale in locales %}
      {% code = locale["code"] %}
      {% entries = locale["entries"] %}
      {% for path, entry in entries %}
        {% node = entry[1] %}
        {% at = "\n  --> #{node.filename.id}:#{node.line_number}:#{node.column_number}" %}
        {% if path == "caramel" || path.starts_with?("caramel.") %}
          {% format = path.starts_with?("caramel.time.formats.") %}
          {% known = ::Caramel::I18n::FRAMEWORK_GROUPS.includes?(path) && entry[0] == "group" %}
          {% known = known || (::Caramel::I18n::FRAMEWORK_TEXTS.includes?(path) &&
                               entry[0] == "message") %}
          {% known = known || ::Caramel::I18n::TIME_LISTS[path] %}
          {% known = known || (framework_keys[path] && entry[0] == "message") %}
          {% known = known || (format && entry[0] == "message") %}
          {% unless known %}
            {% node.raise "unknown framework key '#{path.id}'" + at +
                          "\nRemediation: use the keys listed in ADR 0024 " +
                          "(language, number, time, errors and pages)." %}
          {% end %}
          {% if path == "caramel.number.separator" || path == "caramel.number.delimiter" %}
            {% unless node.size == 1 %}
              {% node.raise "'#{path.id}' must be one character" + at +
                            "\nRemediation: write a single character, such as \",\"." %}
            {% end %}
          {% end %}
          {% count = ::Caramel::I18n::TIME_LISTS[path] %}
          {% listed = node.is_a?(ArrayLiteral) && node.size == count &&
                      node.all? { |name| name.is_a?(StringLiteral) } %}
          {% if count && !listed %}
            {% node.raise "'#{path.id}' needs #{count} names" + at +
                          "\nRemediation: list #{count} strings" +
                          "#{count == 7 ? ", Sunday first".id : "".id}." %}
          {% end %}
          {% if format %}
            {% name = path.split(".").last %}
            {% if code != default && !formats.includes?(name) %}
              {% node.raise "#{code.id} defines '#{path.id}', which the default locale " +
                            "#{default.id} does not" + at +
                            "\nRemediation: add it to the default locale, or remove it." %}
            {% end %}
            {% for directive in node.gsub(/%%/, "").scan(/%-?.?/) %}
              {% unless ::Caramel::I18n::DIRECTIVES.includes?(directive[0]) %}
                {% node.raise "time format '#{path.id}' uses #{directive[0].id}, " +
                              "which Caramel does not format" + at +
                              "\nRemediation: use only " +
                              "#{::Caramel::I18n::DIRECTIVES.join(" ").id}." %}
              {% end %}
            {% end %}
          {% end %}
          {% expected = framework_keys[path] %}
          {% if expected %}
            {% given = locale["placeholders"][path].join(", ") %}
            {% passed = expected.join(", ") %}
            {% if given != passed %}
              {% given = given.empty? ? "none" : given %}
              {% passed = passed.empty? ? "none" : passed %}
              {% node.raise "'#{path.id}' in #{code.id} uses placeholders #{given.id}, " +
                            "but Caramel passes #{passed.id}" + at +
                            "\nRemediation: use exactly these placeholders." %}
            {% end %}
          {% end %}
        {% else %}
          {% reference = base["entries"][path] %}
          {% if code != default && !reference %}
            {% node.raise "#{code.id} defines '#{path.id}', which the default locale " +
                          "#{default.id} does not" + at +
                          "\nRemediation: add the key to the default locale's catalog, " +
                          "or remove it." %}
          {% end %}
          {% if code != default && reference[0] != entry[0] %}
            {% node.raise "'#{path.id}' is a #{entry[0].id} in #{code.id} " +
                          "but a #{reference[0].id} in #{default.id}" + at +
                          "\nRemediation: make it a #{reference[0].id}, " +
                          "as in the default locale." %}
          {% end %}
          {% if code != default && entry[0] != "group" %}
            {% given = locale["placeholders"][path].join(", ") %}
            {% wanted = base["placeholders"][path].join(", ") %}
            {% if given != wanted %}
              {% given = given.empty? ? "none" : given %}
              {% wanted = wanted.empty? ? "none" : wanted %}
              {% node.raise "'#{path.id}' in #{code.id} uses placeholders #{given.id}, " +
                            "but #{default.id} uses #{wanted.id}" + at +
                            "\nRemediation: use the default locale's placeholders." %}
            {% end %}
          {% end %}
          {% if entry[0] == "plural" %}
            {% family = ::Caramel::I18n::FAMILIES[locale["family"]] %}
            {% defined = node.keys.map(&.stringify) %}
            {% for category in family[:integer] %}
              {% unless defined.includes?(category) %}
                {% node.raise "plural '#{path.id}' in #{code.id} lacks the " +
                              "#{category.id} form" + at +
                              "\nRemediation: add #{category.id}:, one of " +
                              "#{family[:integer].join(", ").id} that " +
                              "#{locale["language"].id} needs." %}
              {% end %}
            {% end %}
            {% for form, text in node %}
              {% category = form.stringify %}
              {% unless family[:all].includes?(category) || category =~ ::Caramel::I18n::EXACT %}
                {% text.raise "plural '#{path.id}' in #{code.id} has a #{category.id} form, " +
                              "which #{locale["language"].id} does not use" +
                              "\n  --> #{text.filename.id}:#{text.line_number}:" +
                              "#{text.column_number}" +
                              "\nRemediation: remove it; #{locale["language"].id} uses " +
                              "#{family[:all].join(", ").id} and =N." %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}

    # The keys each locale takes from the default locale: every key the
    # default locale defines, and every framework key. A default locale in a
    # language other than English lists its own missing framework keys.
    {% wanted = [] of StringLiteral %}
    {% for path, entry in base["entries"] %}
      {% if !path.starts_with?("caramel.") && entry[0] != "group" && path != "caramel" %}
        {% wanted << path %}
      {% end %}
    {% end %}
    {% framework = ::Caramel::I18n::FRAMEWORK_TEXTS + ::Caramel::I18n::TIME_LISTS.keys +
                   formats.map { |format| "caramel.time.formats." + format } +
                   framework_keys.keys %}
    {% missing = [] of Nil %}
    {% for locale in locales %}
      {% keys = locale["code"] == default ? [] of StringLiteral : wanted %}
      {% if locale["code"] != default || locale["language"] != "en" %}
        {% keys = keys + framework %}
      {% end %}
      {% for path in keys %}
        {% unless locale["entries"][path] %}
          {% missing << {locale["code"], path, locale["file"]} %}
        {% end %}
      {% end %}
    {% end %}

    {% ::Caramel::I18n::COMPILED[:locales] = locales %}
    {% ::Caramel::I18n::COMPILED[:base] = base %}
    {% ::Caramel::I18n::COMPILED[:formats] = formats %}
    {% ::Caramel::I18n::COMPILED[:prefix] = prefix %}
    {% ::Caramel::I18n::COMPILED[:missing] = missing %}
    {% ::Caramel::I18n::COMPILED[:keys] = wanted.size %}
    ::Caramel::I18n.__locale
    ::Caramel::I18n.__messages
    ::Caramel::I18n.__wording
  end
end

module Caramel::I18n
  # :nodoc:
  # Writes `Caramel::Locale`, `Caramel::I18n::TimeFormat`, the constants,
  # the fiber's locale and the time helpers of `Caramel::Localized`, from
  # what `Caramel.locales` compiled.
  macro __locale
    {% compiled = ::Caramel::I18n::COMPILED %}
    {% locales = compiled[:locales] %}
    {% base = compiled[:base] %}
    {% english = ::Caramel::I18n::ENGLISH %}
    {% settings = [
         {"separator", "number", "::Char"}, {"delimiter", "number", "::Char"},
         {"am", "time", "::String"}, {"pm", "time", "::String"},
         {"months", "time", nil}, {"abbr_months", "time", nil},
         {"days", "time", nil}, {"abbr_days", "time", nil},
       ] %}

    # The time formats `l(time, format)` takes: English's, then those the
    # default locale adds under `caramel.time.formats`.
    enum ::Caramel::I18n::TimeFormat
      {% for format in compiled[:formats] %}
        {{ format.camelcase.id }}
      {% end %}
    end

    # The application's locales, in the order its catalogs declare them.
    enum ::Caramel::Locale
      {% for locale in locales %}
        {{ locale["member"].id }}
      {% end %}

      # The language tag, such as `fr` or `pt-BR`.
      def code : ::String
        case self
        {% for locale in locales %}
          in {{ locale["member"].id }} then {{ locale["code"] }}
        {% end %}
        end
      end

      # The language's own name, from `caramel.language`.
      def name : ::String
        case self
        {% for locale in locales %}
          {% own = locale["entries"]["caramel.language"] %}
          {% english_name = locale["language"] == "en" ? "English" : locale["code"] %}
          in {{ locale["member"].id }} then {{ own ? own[1] : english_name }}
        {% end %}
        end
      end

      def default? : ::Bool
        self == {{ base["member"].id }}
      end

      def self.default : self
        {{ base["member"].id }}
      end

      # The locale *tag* names, ignoring case, or nil.
      def self.parse?(tag : ::String) : self?
        {% for locale in locales %}
          {% member = locale["member"].id %}
          return {{ member }} if tag.compare({{ locale["code"] }}, case_insensitive: true) == 0
        {% end %}
      end

      # The writing direction, for the layout's `dir` attribute.
      def dir : ::String
        case self
        {% for locale in locales %}
          {% rtl = ::Caramel::I18n::RIGHT_TO_LEFT.includes?(locale["language"]) %}
          in {{ locale["member"].id }} then {{ rtl ? "rtl" : "ltr" }}
        {% end %}
        end
      end

      # The plural category of *count* in this locale's language.
      def plural(count : ::Int) : ::Caramel::I18n::Plural
        case self
        {% for locale in locales %}
          {% rule = "::Caramel::I18n::Rules.#{locale["family"].id}(count)" %}
          in {{ locale["member"].id }} then {{ rule.id }}
        {% end %}
        end
      end

      # Number and time names: this locale's, else the default locale's,
      # else English's.
      {% for setting in settings %}
        {% path = "caramel." + setting[1] + "." + setting[0] %}
        def {{ setting[0].id }}{% if setting[2] %} : {{ setting[2].id }}{% end %}
          case self
          {% for locale in locales %}
            {% found = locale["entries"][path] || base["entries"][path] %}
            {% value = found ? found[1] : english[setting[1]][setting[0]] %}
            in {{ locale["member"].id }}
              {% if value.is_a?(ArrayLiteral) %}
                { {{ value.splat }} }
              {% elsif setting[2] == "::Char" %}
                {{ value.chars.first }}
              {% else %}
                {{ value }}
              {% end %}
          {% end %}
          end
        end
      {% end %}

      # The pattern of *format*: this locale's, else the default locale's,
      # else English's.
      def time_pattern(format : ::Caramel::I18n::TimeFormat) : ::String
        case self
        {% for locale in locales %}
          in {{ locale["member"].id }}
            case format
            {% for format in compiled[:formats] %}
              {% path = "caramel.time.formats." + format %}
              {% found = locale["entries"][path] || base["entries"][path] %}
              {% pattern = found ? found[1] : english[:time][:formats][format] %}
              in ::Caramel::I18n::TimeFormat::{{ format.camelcase.id }} then {{ pattern }}
            {% end %}
            end
        {% end %}
        end
      end
    end

    module ::Caramel::I18n
      # Whether every locale but the default is served under `/CODE`.
      PREFIX = {{ compiled[:prefix] }}

      # How many messages the default locale's catalog holds.
      KEYS = {{ compiled[:keys] }}

      # Each key a locale takes from the default locale: its code, the key
      # and the catalog's file.
      MISSING = [
        {% for entry in compiled[:missing] %}
          { {{ entry[0] }}, {{ entry[1] }}, {{ entry[2] }} },
        {% end %}
      ] of {::String, ::String, ::String}
    end

    class ::Fiber
      # The locale this fiber works in, and the page it renders without its
      # locale prefix and `locale` parameter; set only by
      # `Caramel::I18n.with`.
      property caramel_locale : ::Caramel::Locale? = nil
      property caramel_path : ::String? = nil
    end

    module ::Caramel::Localized
      # *time* in the request locale's *format*: `l(book.published_at, :date)`.
      # Times are written in their own location.
      def l(time : ::Time,
            format : ::Caramel::I18n::TimeFormat = ::Caramel::I18n::TimeFormat::Datetime) : ::String
        ::Caramel::I18n.format_time(time, locale.time_pattern(format), locale)
      end

      # This page in *target*, for a language switcher. Give the link
      # `hx_boost: "false"`, so the browser loads the whole page in the new
      # language.
      def switch_locale_path(target : ::Caramel::Locale) : ::String
        ::Caramel::I18n.switch_path(target)
      end
    end
  end

  # :nodoc:
  # Writes `Caramel::Messages`, one struct per group of the default locale's
  # catalog with one method per message, from what `Caramel.locales`
  # compiled. Each method's `case` has a branch per locale: its text, or the
  # default locale's when it has none, and locales with the same text share
  # one. A plural's `else` is `other`, or its family's last integer category.
  macro __messages
    {% compiled = ::Caramel::I18n::COMPILED %}
    {% locales = compiled[:locales] %}
    {% base = compiled[:base] %}
    {% children = {"" => [] of StringLiteral} %}
    {% for path, entry in base["entries"] %}
      {% unless path == "caramel" || path.starts_with?("caramel.") %}
        {% parent = path.split(".")[0..-2].join(".") %}
        {% children[parent] << path %}
        {% if entry[0] == "group" %}
          {% children[path] = [] of StringLiteral %}
        {% end %}
      {% end %}
    {% end %}

    {% for group, members in children %}
      {% type = "::Caramel::Messages" %}
      {% unless group.empty? %}
        {% type = type + "::" + group.split(".").map(&.camelcase).join("::") %}
      {% end %}
      # One group of messages, in the locale it was made for.
      struct {{ type.id }}
        # :nodoc:
        def initialize(@locale : ::Caramel::Locale)
        end

        {% types = {} of String => Nil %}
        {% for path in members %}
          {% entry = base["entries"][path] %}
          {% key = path.split(".").last %}
          {% names = base["placeholders"][path] %}
          {% if entry[0] == "group" %}
            {% child = key.camelcase %}
            {% if types[child] %}
              {% node = entry[1] %}
              {% node.raise "catalog keys '#{types[child].id}' and '#{path.id}' both name " +
                            "the group type #{child.id}" +
                            "\n  --> #{node.filename.id}:#{node.line_number}:" +
                            "#{node.column_number}" +
                            "\nRemediation: rename one of the two groups." %}
            {% end %}
            {% types[child] = path %}
            def {{ key.id }} : {{ type.id }}::{{ child.id }}
              {{ type.id }}::{{ child.id }}.new(@locale)
            end
          {% else %}
            {% clauses = {} of String => Nil %}
            {% args = names.map { |name| "#{name.id}: #{name.id}" } %}
            {% for locale in locales %}
              {% source = locale["entries"][path] ? locale : base %}
              {% member = "::Caramel::Locale::" + source["member"] %}
              {% if entry[0] == "message" && names.empty? %}
                {% body = source["entries"][path][1].stringify %}
              {% elsif entry[0] == "message" %}
                {% texts = source["texts"][path][0] %}
                {% parts = texts.map { |part| part[0] ? part[1] : part[1].stringify } %}
                {% body = "::Caramel::I18n.compose({#{parts.join(", ").id}}, " +
                          "{#{args.join(", ").id}})" %}
              {% else %}
                {% exact = [] of Nil %}
                {% categories = [] of Nil %}
                {% for form, text in source["entries"][path][1] %}
                  {% form_key = form.stringify %}
                  {% parsed = source["texts"][path + "|" + form_key] %}
                  {% if names.empty? && !parsed[1].includes?("count") %}
                    {% form_body = text.stringify %}
                  {% else %}
                    {% number = "::Caramel::I18n.number(#{member.id}, count)" %}
                    {% parts = parsed[0].map { |part| part[0] ? part[1] : part[1].stringify } %}
                    {% parts = parts.map { |part| part == "count" ? number : part } %}
                    {% if parts.empty? %}
                      {% parts = ["\"\""] %}
                    {% end %}
                    {% form_args = args.empty? ? ["count: count"] : args %}
                    {% form_body = "::Caramel::I18n.compose({#{parts.join(", ").id}}, " +
                                   "{#{form_args.join(", ").id}})" %}
                  {% end %}
                  {% if form_key =~ ::Caramel::I18n::EXACT %}
                    {% exact << {form_key[1..-1], form_body} %}
                  {% else %}
                    {% categories << {form_key, form_body} %}
                  {% end %}
                {% end %}
                {% family = source["family"] %}
                {% last = ::Caramel::I18n::FAMILIES[family][:integer].last %}
                {% fallback = categories.find { |form| form[0] == "other" } ||
                              categories.find { |form| form[0] == last } %}
                {% whens = categories.reject { |form| form[0] == fallback[0] } %}
                {% body = fallback[1] %}
                {% unless whens.empty? %}
                  {% rule = "::Caramel::I18n::Rules.#{family.id}(count)" %}
                  {% lines = whens.map { |form| "when .#{form[0].id}? then #{form[1].id}" } %}
                  {% body = "case #{rule.id}\n#{lines.join("\n").id}\nelse #{body.id}\nend" %}
                {% end %}
                {% unless exact.empty? %}
                  {% lines = exact.map { |form| "when #{form[0].id} then #{form[1].id}" } %}
                  {% body = "case count\n#{lines.join("\n").id}\nelse #{body.id}\nend" %}
                {% end %}
              {% end %}
              {% unless clauses[body] %}
                {% clauses[body] = [] of StringLiteral %}
              {% end %}
              {% clauses[body] << "::Caramel::Locale::" + locale["member"] %}
            {% end %}
            {% keywords = names.empty? ? "" : ", *, " + names.join(", ") %}
            {% if entry[0] == "plural" %}
              def {{ key.id }}(count : ::Int{{ keywords.id }})
            {% elsif names.empty? %}
              def {{ key.id }} : ::String
            {% else %}
              def {{ key.id }}(*, {{ names.join(", ").id }})
            {% end %}
              case @locale
              {% for body, members in clauses %}
                in {{ members.join(", ").id }}
                  {{ body.id }}
              {% end %}
              end
            end
          {% end %}
        {% end %}
      end
    {% end %}
  end

  # :nodoc:
  # Redefines each of Caramel's own messages that a catalog translates, with
  # the same signature: the request locale's text, else the default
  # locale's, else English.
  macro __wording
    {% compiled = ::Caramel::I18n::COMPILED %}
    {% locales = compiled[:locales] %}
    {% base = compiled[:base] %}
    {% for message in ::Caramel::I18n::FRAMEWORK_MESSAGES %}
      {% path = "caramel." + message[0] %}
      {% names = message[3] %}
      {% if locales.any? { |locale| locale["entries"][path] } %}
        {% clauses = {} of String => Nil %}
        {% for locale in locales %}
          {% source = nil %}
          {% if locale["entries"][path] %}
            {% source = locale %}
          {% elsif base["entries"][path] %}
            {% source = base %}
          {% end %}
          {% body = "previous_def" %}
          {% if source && names.empty? %}
            {% body = source["entries"][path][1].stringify %}
          {% elsif source %}
            {% texts = source["texts"][path][0] %}
            {% parts = texts.map { |part| part[0] ? part[1] : part[1].stringify } %}
            {% args = names.map { |name| "#{name.id}: #{name.id}" } %}
            {% body = "::Caramel::I18n.compose({#{parts.join(", ").id}}, " +
                      "{#{args.join(", ").id}})" %}
          {% end %}
          {% unless clauses[body] %}
            {% clauses[body] = [] of StringLiteral %}
          {% end %}
          {% clauses[body] << "::Caramel::Locale::" + locale["member"] %}
        {% end %}
        {% params = names.empty? ? "" : "(" + names.join(", ") + ")" %}
        module {{ message[1].id }}
          def {{ message[2].id }}{{ params.id }} : ::String
            case ::Caramel::I18n.locale
            {% for body, members in clauses %}
              in {{ members.join(", ").id }}
                {{ body.id }}
            {% end %}
            end
          end
        end
      {% end %}
    {% end %}
  end
end
