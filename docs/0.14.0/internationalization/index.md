Guides / Internationalization

# Speak your users’ language.

Add typed translations, choose a language for each request, and localize numbers, dates, and validation messages in Caramel 0.14.0.

| Contract | Value |
| --- | --- |
| Release | 0.14.0 |
| Needs | An application whose `config/application.cr` `frappe make locale` can wire |
| You will have | Typed messages, a language for each request, and localized numbers, dates and validation messages |
| Proved by | `frappe check` · `frappe translations` · `frappe corretto` |

## The guide in six stages {#c-i18n-map}

11 sections · read in order the first time

- **1 · Start**

  - [Enable translations](#c-i18n-enable)
- **2 · Write**

  - [Write Crystal catalogs](#c-i18n-catalogs)
  - [Call typed messages](#c-i18n-messages)
- **3 · Choose**

  - [Choose the request language](#c-i18n-language)
  - [Add a language switcher](#c-i18n-switcher)
- **4 · Localize**

  - [Format numbers and dates](#c-i18n-formats)
  - [Translate errors and keep text safe](#c-i18n-errors)
  - [Carry language into background work](#c-i18n-jobs)
- **5 · Look up**

  - [Look up catalog keys](#c-i18n-reference)
- **6 · Limits**

  - [What does not compile](#c-i18n-refusals)
  - [Not covered yet](#c-i18n-limits)

Stage 1 · Start

## Enable translations {#c-i18n-enable}

Internationalization is opt-in. Inside your application, add a locale before generating the resources you want translated. A plain application does not compile the i18n implementation.

**Terminal · inside your application**

```bash
frappe make locale fr
frappe check
```

**Expect:** Creates `app/locales/en.cr` and `app/locales/fr.cr` and wires `config/application.cr`, printing a `Generated` line for each file.

New resource generation then writes `t.` calls and adds messages to the default catalog. Existing resource views keep their text until you replace it with message calls.

The configuration requires `caramel/i18n` after `caramel`, loads the locale files, then calls `Caramel.locales default: "en"` once, before loading views. If your configuration has been customized, follow the generator’s instructions to add that wiring by hand.

Stage 2 · Write

## Write Crystal catalogs {#c-i18n-catalogs}

Catalogs are Crystal named tuples. Add the groups below to the generated catalogs, keeping their existing `common` and resource messages. Each file has one `Caramel.locale` declaration; these excerpts show only the added groups. Set `caramel.language` to the language’s own display name.

**app/locales/en.cr · catalog excerpt**

```crystal
Caramel.locale "en", {
  home: {greeting: "Hello, %{name}!"},
  library: {
    count: {"=0": "No books", one: "%{count} book", other: "%{count} books"},
  },
}
```

**app/locales/fr.cr · catalog excerpt**

```crystal
Caramel.locale "fr", {
  caramel: {
    language: "Français",
    number: {separator: ",", delimiter: " "},
    time: {formats: {date: "%d/%m/%Y"}},
    errors: {blank: "ne peut pas être vide"},
    pages: {not_found: "Page introuvable"},
  },
  home: {greeting: "Bonjour, %{name} !"},
  library: {
    count: {
      "=0": "Aucun livre",
      one: "%{count} livre",
      many: "%{count} de livres",
      other: "%{count} livres",
    },
  },
}
```

The default locale defines application keys and their placeholders. Other locales may omit keys and use the default text. Use lowercase identifiers for keys.

## Call typed messages {#c-i18n-messages}

Views and actions expose `t`, `locale`, and `l`, including inside `markup`. A message’s placeholders become named arguments. A plural takes its whole-number count first.

**Inside a view’s blueprint**

```crystal
h1 { t.home.greeting(name: "Ann") }
p { t.library.count(3) }
p { l(1234.5, 2) }
p { l(Time.utc(2026, 10, 2), :date) }
```

In French, these calls produce `Bonjour, Ann !`, `3 livres`, `1 234,50`, and `02/10/2026`.

Plurals follow CLDR cardinal rules for whole numbers. English requires `one` and `other`; French also requires `many`. Optional exact forms such as `"=0"` take priority, and `%{count}` uses its number separators.

Stage 3 · Choose

## Choose the request language {#c-i18n-language}

A valid `?locale=` switch on GET or HEAD changes the remembered language. Otherwise, selection follows this order:

1. A non-default locale prefix, when enabled.
2. The remembered locale cookie.
3. The best supported `Accept-Language` match.
4. The application’s default locale.

Locale codes include `fr`, `pt-BR`, and `zh-Hant`. To enable language prefixes, change the existing configuration call:

**config/application.cr · replace the existing locales call**

```crystal
Caramel.locales default: "en", prefix: true
```

With this setting, `/fr/books` routes to `/books` in French. The default locale stays unprefixed; `/en/books` does not select English. Prefixes use lowercase codes, such as `/pt-br/books`. Generated resource path helpers already include the request locale’s prefix. Use `localize_path("/account")` for a manually written application path.

Routed responses identify their language with `Content-Language`. Responses selected without a prefix also vary by `Accept-Language` and `Cookie`. A language-switch request returns a 303 redirect, or a 200 response with `HX-Redirect` for htmx, and remembers the choice in a secure cookie. Unknown switch values are ignored.

## Add a language switcher {#c-i18n-switcher}

Use each locale’s own name and let `switch_locale_path` preserve the current page and query. Reload the full page when switching so the layout and all visible text use the selected language.

**Inside a view’s blueprint**

```crystal
nav(aria_label: "Language") do
  Caramel::Locale.each do |language|
    a(href: switch_locale_path(language), hx_boost: "false") { language.name }
  end
end
```

The layout’s `html` element should use `lang: Caramel.language`; generated applications already do. Add `dir: locale.dir` when supporting right-to-left languages, and check your styles in both directions.

Stage 4 · Localize

## Format numbers and dates {#c-i18n-formats}

`l(number, decimals)` uses `caramel.number.separator` and `delimiter`. `l(time, :date)` chooses a named time pattern; built-in names include `:date`, `:time`, `:datetime`, and `:short_date`. The default catalog can add more named formats.

Supply translated month and day names under `caramel.time` when your patterns use them. Formatting data falls back from the selected locale to the default locale, then to English. A time keeps its own location; formatting does not convert timezones.

## Translate errors and keep text safe {#c-i18n-errors}

The reserved `caramel.errors` keys translate contract and changeset messages. `caramel.pages` includes `check_request`, `not_found`, and `expired_form`. The French catalog above translates blank validation errors and the router’s 404 body. Missing framework messages fall back through the default catalog to English.

Errors are translated when they are created. JSON keeps its `errors` object with arrays of messages per field, using the request’s locale. Framework wording is available through `Caramel::Wording` and `SugarORM::Wording`, including `Caramel::Wording.expired_form`.

Keep catalog messages as text. Views escape normal placeholder values. For a message containing a link or other markup, pass a `markup { … }` result as the placeholder: only that trusted HTML is emitted as markup, while catalog text and other values remain escaped.

## Carry language into background work {#c-i18n-jobs}

A request’s locale belongs to its fiber and is restored afterward. Spawned fibers and Cold Brew jobs start in the default locale. Give a translated job a `param locale : String`, enqueue it with the request’s `Caramel.language`, and wrap the work that creates messages or errors in an explicit locale scope.

**Inside a job’s perform method · locale is the payload field**

```crystal
target = Caramel::Locale.parse?(locale) || Caramel::Locale.default
Caramel::I18n.with(target) do
  messages = Caramel::Messages.new(target)
  greeting = messages.home.greeting(name: "Ann")
  # Use greeting in the job’s output.
end
```

Stage 5 · Look up

## Look up catalog keys {#c-i18n-reference}

The reserved `caramel` section takes only these keys. A locale that leaves one out uses the default locale’s, then English.

| Key | Meaning |
| --- | --- |
| `language` | The language’s own name, such as Français |
| `number.separator`, `number.delimiter` | One character each; English uses . and , |
| `time.months`, `time.abbr_months` | 12 names, January first |
| `time.days`, `time.abbr_days` | 7 names, Sunday first |
| `time.am`, `time.pm` | The text for %p |
| `time.formats.NAME` | A pattern; date, time, datetime and short_date are built in |

A pattern uses only `%Y %m %-m %d %-d %H %-H %I %-I %M %S %p %B %b %A %a %%`. `%I` is the 12-hour clock, and `%-` drops the leading zero.

The `errors` and `pages` keys translate Caramel’s own messages:

| Key | English text |
| --- | --- |
| `errors.required` | is required |
| `errors.must_be_file` | must be a file |
| `errors.json_type` | must be a JSON %{type} |
| `errors.invalid_value` | must be a valid %{type} |
| `errors.at_least` | must be at least %{min} |
| `errors.at_least_characters` | must be at least %{min} characters |
| `errors.at_most` | must be at most %{max} |
| `errors.at_most_characters` | must be at most %{max} characters |
| `errors.at_least_items` | must have at least %{min} item(s) |
| `errors.at_most_items` | must have at most %{max} item(s) |
| `errors.duplicate_item` | repeats an earlier item |
| `errors.duplicate_field` | Duplicate field: %{name} |
| `errors.unknown_field` | Unknown field: %{name} |
| `errors.expected_json_object` | Expected a JSON object |
| `errors.url` | must be an absolute http or https URL |
| `errors.blank` | can't be blank |
| `errors.greater_than` | must be greater than %{than} |
| `errors.less_than` | must be less than %{than} |
| `errors.too_short` | should be at least %{min} character(s) |
| `errors.too_long` | should be at most %{max} character(s) |
| `errors.invalid_format` | has invalid format |
| `errors.invalid` | is invalid |
| `errors.taken` | has already been taken |
| `errors.record_gone` | Record no longer exists |
| `errors.record_stale` | Record changed since you loaded it |
| `pages.check_request` | Check your request |
| `pages.not_found` | Not found |
| `pages.expired_form` | This form has expired or came from another site. Reload the page and try again. |

Plural rules are built in for `af am ar as ast az be bg bn bs ca cs cy da de el en es et eu fa fi fo fr fy ga gl gu he hi hr hu id is it ja ka kk km kn ko ky lb lo lt lv mk ml mn mr ms my nb ne nl nn no pl pt pt-PT ro ru sk sl so sq sr sv sw ta te th tr uk ur uz vi yue zh zu`. A tag with a region or script uses its language’s rules, so `pt-BR` uses `pt`’s. For any other language, name one with the same rules: `Caramel.locale "eo", {…}, plural: "en"`. `locale.dir` is `rtl` for `ar he fa ur ps sd ug yi dv ckb`.

Stage 6 · Limits

## What does not compile {#c-i18n-refusals}

Each mistake below stops the build at the line that causes it.

| Condition | Outcome |
| --- | --- |
| A misspelled message name or a missing argument in a `t.` call | fails compilation |
| Crystal string interpolation in catalog text instead of `%{name}` placeholders | fails compilation |
| A key that is not a lowercase identifier, a reserved word, or a malformed catalog | fails compilation |
| A non-default locale that defines an application key the default locale lacks | fails compilation |
| A non-default locale that changes a message’s placeholders or kind | fails compilation |
| A locale that omits a required plural category | fails compilation |
| A framework `errors` or `pages` key that changes the placeholders of its English text | fails compilation |
| A time pattern that uses a directive outside the listed set, or malformed `caramel.time` or `caramel.number` data | fails compilation |
| A non-default locale that adds a time format name | fails compilation |
| A language without built-in plural rules and no `plural:` | fails compilation |

## Not covered yet {#c-i18n-limits}

Caramel supports typed text messages, whole-number plurals, number and time formatting, and request-local language selection. These are not implemented:

- Select and gender messages.
- Currency formatting.
- Relative time formatting.
- Translated URL segments.
- Database-backed catalogs.
- Automatic job locale propagation.
- An unused-key report.

[Read the internationalization design and API details ↗](https://github.com/caramelizedev/caramel/blob/v0.14.0/docs/decisions/0024-internationalization.md)

Prove it

## Check translations and requests {#c-i18n-check}

Use the completeness report alongside the compiler and request specs. `frappe translations` prints `MISSING code key file` and exits 1 while translations are missing. It includes framework wording and formatting data, so a newly generated locale has more to fill in than application text. Missing keys can still compile and fall back intentionally.

Use a fresh Corretto session to test browser language negotiation without a remembered locale. With a Book resource and a layout using `Caramel.language`:

**spec/requests/books_spec.cr · inside an example**

```crystal
Corretto.session do |client, db|
  response = client.get("/books",
    headers: {"Accept-Language" => "fr"})
  response.should have_header("Content-Language", "fr")
  response.should have_html { html(lang: "fr") }
end
```

Also assert translated text, fallback behavior, validation messages in HTML and JSON, switch redirects, and form submissions under a locale prefix.

**Terminal · application checks**

```bash
frappe check
frappe translations
frappe corretto
```

**Passing:** `frappe check` compiles the catalogs. `frappe translations` prints OK with the locale and key counts and exits 0, or lists only `MISSING` keys you leave on the fallback on purpose. The Corretto example sees `Content-Language: fr`.

[← Mount a component](https://caramelize.dev/cookbook/0.14.0/third-party-components/index.md) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/internationalization/
