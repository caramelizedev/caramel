# ADR 0024: Built-in internationalization

Date: 2026-10-02

Status: accepted.

## Context

Internationalization is built in. An application that never opts in pays nothing: no
per-request work, no allocation, no added binary code and no extra compile step.

## Decision

1. **Hooks with English and identity defaults** (`src/caramel/wording.cr`, `src/sugar_orm/wording.cr`).
   - Every framework message comes from a method of `Caramel::Wording` or `SugarORM::Wording` that returns the English text. That includes the router's 404 body (`Caramel::Router.not_found`) and `Action#not_found`'s default.
   - `Caramel.language` returns `"en"`, and `Caramel.localize_path` returns its path unchanged. Resource path helpers pass through `Caramel.localize_path`, so with `prefix: true` generated links and forms carry the prefix.
   - `Application#handle` routes through `localized`, which only yields, and `#call` streams through `streaming`, which only yields.
   - `CommandLine.translations` prints that no locales are declared.
   - `Caramel::Wording.expired_form` replaces `Caramel::Application::EXPIRED_FORM`, with no deprecation release, an explicit exception to `CONTRIBUTING.md`.
2. **`require "caramel/i18n"` is the only way in.** `src/caramel.cr` does not require it. It redefines the hooks above. A `macro finished` guard refuses a program that requires it without calling `Caramel.locales`.
3. **Catalogs** (`src/caramel/i18n/catalog.cr`) are Crystal literals in `app/locales/CODE.cr`, with no `{{ run }}` helper and no build step.
   - `Caramel.locale(code, messages, plural = nil)` records a catalog. Its code is a language tag, such as `fr`, `pt-BR` or `zh-Hant`.
   - `Caramel.locales(default:, prefix: false)` checks every catalog and writes the code. A value is text, a plural (a named tuple whose keys are all CLDR categories or `=N`) or a group. So a group's keys cannot all be category names.
   - Keys are lowercase identifiers. They exclude Crystal's keywords, the methods every value has, `locale` and `finalize`. `%{name}` is a placeholder (a literal `%{` cannot be written); placeholders exclude the same names but allow `finalize`, which is an argument.
   - Every mistake is a compile error at the offending catalog value, with a fixed problem text and a remediation: an invalid code, a duplicate locale, an invalid or reserved key, interpolated text, a key the default locale lacks, different placeholders or kind of value, a missing or unused plural form, a language without plural rules, an unknown framework key, an unsupported time directive, a malformed separator or name list, and a missing or unknown default.
   - A locale may omit keys the default locale has: a missing key uses the default locale's text, and `translations` lists it. A key it defines must exist in the default locale, with the same kind of value and placeholders.
   - The reserved `caramel:` section supplies formatting data (see Catalog reference).
4. **What `Caramel.locales` writes:**
   - **`Caramel::Locale`**, an enum of the declared locales. It answers each locale's code, name, direction, plural category and formatting data.
   - **`Caramel::Messages`**, a struct per catalog group, which `t` returns. Each message is a typed method (`t.books.count(3)`, `t.home.greeting(name: n)`) whose `case` over the locale has a branch per locale. Placeholders are named arguments; a plural takes its count first.
   - **The redefinitions of every framework message some catalog translates.** Each has the hook's signature and answers the request locale's text, else the default locale's, else the English one through `previous_def`.
5. **Plural rules** (`src/caramel/i18n/plural.cr`) are CLDR 47's cardinal rules for whole numbers, one method per family of languages. A plural message must define its family's integer categories, and may define its other categories and exact `=N` counts.
6. **Composition and escaping.** A message with placeholders is built by `Caramel::I18n.compose`. When an argument is a `Caramel::HTML::Safe`, the message is safe HTML: the catalog's text and other arguments are escaped and the safe argument is written as is. Otherwise the message is plain text, which views escape.
7. **Resolution** (`Application#localized`, `src/caramel/i18n/localized.cr`):
   - With `prefix: true`, a first path segment that is a non-default locale's lowercase code selects that locale and is removed before routing. The default locale has no prefix.
   - A GET or HEAD with a `locale` parameter that names a declared locale is answered without routing: a 303 to the same page in that locale, or 200 with `HX-Redirect` for htmx. Both set the `__Host-caramel_locale` cookie for a year. An unknown value is ignored.
   - Otherwise the locale is the prefix's, else the cookie's, else the best `Accept-Language` match, else the default. An `Accept-Language` over 1,024 bytes is ignored; only its first 16 ranges are read. A range matches its exact tag, then the first locale in its language.
   - Routing and streamed bodies run inside `Caramel::I18n.with`, which binds the locale to the fiber and restores it afterwards. Every response says `Content-Language`; a negotiated one adds `Vary: Accept-Language, Cookie`. A prefix locale that differs from the cookie updates it.
   - `handle` secures every response the hook returns, the switch's redirect included.
8. **Framework messages render when they are created.** Errors keep their `Hash(String, Array(String))` shape, and JSON clients receive localized text. A message created outside a request, `spawn`ed fibers and Cold Brew jobs use the default locale unless wrapped in `Caramel::I18n.with`: a job carries `param locale : String` and wraps its work in it.
9. **Frappé:**
   - Generated applications stay plain English until `frappe make locale CODE`, which writes `app/locales/CODE.cr`. The first time it also writes `app/locales/en.cr` and the i18n lines in `config/application.cr`.
   - After that, `frappe make resource` writes `t.` calls in place of English, and inserts the resource's messages into the default locale's catalog. It refuses a field or plural that would be an invalid catalog key.
   - `frappe translations` runs the application's `translations` command, which lists each `MISSING code key file` and exits 1 while any key is missing.

### Catalog reference

The reserved `caramel:` section takes only these keys; an omitted key uses the default locale's, then English.

|Key|Value|English|
|---|---|---|
|`language`|The language's own name|`English`|
|`number.separator`, `number.delimiter`|One character each|`.` and `,`|
|`time.months`, `time.abbr_months`|12 names, January first|`January` …, `Jan` …|
|`time.days`, `time.abbr_days`|7 names, Sunday first|`Sunday` …, `Sun` …|
|`time.am`, `time.pm`|Text|`AM`, `PM`|
|`time.formats.NAME`|A pattern|`date` `%B %-d, %Y`, `time` `%-I:%M %p`, `datetime` `%B %-d, %Y %-I:%M %p`, `short_date` `%b %-d`|

- A pattern uses only `%Y %m %-m %d %-d %H %-H %I %-I %M %S %p %B %b %A %a %%`. `%I` is the 12-hour clock, and `%-` drops the leading zero.
- The default locale may add format names, which `l(time, :name)` takes; other locales only translate existing names.

`errors` and `pages` translate Caramel's own messages. Each uses exactly the placeholders its English text shows.

|Key|English|
|---|---|
|`errors.required`|is required|
|`errors.must_be_file`|must be a file|
|`errors.json_type`|must be a JSON %{type}|
|`errors.invalid_value`|must be a valid %{type}|
|`errors.at_least`|must be at least %{min}|
|`errors.at_least_characters`|must be at least %{min} characters|
|`errors.at_most`|must be at most %{max}|
|`errors.at_most_characters`|must be at most %{max} characters|
|`errors.duplicate_field`|Duplicate field: %{name}|
|`errors.unknown_field`|Unknown field: %{name}|
|`errors.expected_json_object`|Expected a JSON object|
|`errors.url`|must be an absolute http or https URL|
|`errors.blank`|can't be blank|
|`errors.greater_than`|must be greater than %{than}|
|`errors.less_than`|must be less than %{than}|
|`errors.too_short`|should be at least %{min} character(s)|
|`errors.too_long`|should be at most %{max} character(s)|
|`errors.invalid_format`|has invalid format|
|`errors.invalid`|is invalid|
|`errors.taken`|has already been taken|
|`errors.record_gone`|Record no longer exists|
|`pages.check_request`|Check your request|
|`pages.not_found`|Not found|
|`pages.expired_form`|This form has expired or came from another site. Reload the page and try again.|

Plural rules are built in for these languages:

- `af am ar as ast az be bg bn bs ca cs cy da de el en es et eu fa fi fo fr fy ga gl gu he hi hr hu id is it ja ka kk km kn ko ky lb lo lt lv mk ml mn mr ms my nb ne nl nn no pl pt pt-PT ro ru sk sl so sq sr sv sw ta te th tr uk ur uz vi yue zh zu`.
- A tag with a region or script uses its language's rules, so `pt-BR` uses `pt`'s.
- Any other language names one with the same rules: `Caramel.locale "eo", {…}, plural: "en"`.

`Locale#dir` is `rtl` for `ar he fa ur ps sd ug yi dv ckb`, and `ltr` for every other language.

## Reasons

- Catalogs as Crystal literals and typed message methods make every catalog mistake a compile error on the catalog's line; unused messages add nothing to the binary.
- Hooks that one opt-in require replaces keep a plain application unchanged and free of i18n code.
- Rendering at creation keeps the error hash and JSON shape clients read.
- Escaping by default, a per-request locale and localized form URLs avoid injection, races and POST-to-GET redirects.
- Falling back to the default locale and reporting gaps never blocks shipping.
- Rejected: YAML catalogs through a `{{ run }}` macro, because they add a compile step and move errors off the catalog's line.
- Rejected: Frappé-generated code, because it drifts.
- Rejected: bundled CLDR formatting data, because it enlarges every localized binary.
- Rejected: i18n-ready applications from day one, because all would pay.
