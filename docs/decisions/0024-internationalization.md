# ADR 0024: Built-in internationalization

Date: 2026-10-02

Status: accepted.

## Context

- The owner wants internationalization built into Caramel. An application that never opts in must pay nothing: no per-request work, no allocation, no added binary code and no extra compile step.
- The owner fixed these choices:
  - **Catalogs are Crystal literals.** `app/locales/CODE.cr` calls `Caramel.locale "fr", { … }` with a named tuple literal. The compiler parses it, so an error lands on the catalog's own line. There is no `{{ run }}` helper and no build step.
  - **Each message compiles to a typed method.** The compiler checks `t.books.count(3)` and `t.home.greeting(name: n)`. A message nobody calls is never typed, so it never reaches the binary.
  - **Locale resolution:** a `?locale=` switch, then an opt-in `/fr/…` prefix, then the remembered cookie, then the best `Accept-Language` match, then the default. Existing URLs keep working.
  - **Catalogs supply the formatting data.** Number separators, month and day names and time patterns live in a reserved `caramel:` section. English is built in.
  - **Generated applications stay plain English** until `frappe make locale CODE`. After that, `frappe make resource` writes `t.` calls and catalog entries.
  - **Caramel's own messages are translated through the same catalogs:** contract and changeset errors, the "Check your request" page and the expired-form page. They render in the request's locale when they are created.
- Research into other frameworks gave these lessons:

  |Lesson|Evidence|
  |---|---|
  |Keys are compile-time methods|Rails i18n-tasks names "missing keys only blow up at runtime" as the core flaw. Paraglide, Rosetta (0 B/op) and fluent-typed generate one typed function per message.|
  |CLDR plural categories, checked per locale|Rails ships English rules only. Laravel and vue-i18n use positional plurals. Rosetta and FormatJS validate the required categories.|
  |Text is escaped by default; only `Caramel::HTML::Safe` arguments are raw|Rails' `_html` semantics. Laravel's `{!! __() !!}` and vue-i18n CVE-2025-53892 show the risk.|
  |The locale is bound per request and restored, never process-global|ruby-i18n #723, Laravel Octane's `FlushLocaleState`, i18n.cr's global races.|
  |Ordered resolution, a bounded Accept-Language parse, `Content-Language` and `Vary`|Django's `LocaleMiddleware`, CVE-2023-23969, next-intl's and Paraglide's strategies.|
  |Forms post to localized URLs|The mcamara POST→GET redirect bug.|
  |A missing translation falls back to the default locale, and a command reports it|Rosetta's strict-complete rule blocks shipping. go-i18n returns the text plus an error; Lingui and Angular gate this in CI.|
  |Zero cost comes from opt-in requires and hooks|Django's `USE_I18N` overhead; Caramel's own `caramel/corretto` and `flag?(:caramel_development)` precedents.|

## Decision

1. **Hooks with English and identity defaults** (`src/caramel/wording.cr`, `src/sugar_orm/wording.cr`).
   - Every framework message comes from a method of `Caramel::Wording` or `SugarORM::Wording` that returns today's English. That includes the router's 404 body for a path no route matches (`Caramel::Router.not_found`), and `Action#not_found`'s default.
   - `Caramel.language` returns `"en"`, and `Caramel.localize_path` returns its path unchanged. Resource path helpers pass through `Caramel.localize_path`.
   - `Application#handle` routes through `localized`, which only yields, and `#call` streams through `streaming`, which only yields.
   - `CommandLine.translations` prints that the application declares no locales.
   - `Caramel::Application::EXPIRED_FORM` is removed in favour of `Caramel::Wording.expired_form`, without a deprecation release. This is an explicit exception to the deprecation rule in `CONTRIBUTING.md`: the owner chose the clean cutover, and nothing Caramel generates refers to the constant.
2. **`require "caramel/i18n"` is the only way in.** `src/caramel.cr` does not require it. It redefines the hooks above, so an application that never requires it compiles none of its code. A `macro finished` guard refuses a program that requires it without calling `Caramel.locales`.
3. **Catalogs** (`src/caramel/i18n/catalog.cr`):
   - `Caramel.locale(code, messages, plural = nil)` records a catalog. Its code is a language tag, such as `fr`, `pt-BR` or `zh-Hant`.
   - `Caramel.locales(default:, prefix: false)` checks every catalog and writes the code. A value is text, a plural (a named tuple whose keys are all CLDR categories or `=N`) or a group. So a group's keys cannot all be category names.
   - Keys are lowercase identifiers. They exclude Crystal's keywords, the methods every value has, and `locale`. `%{name}` is a placeholder; a literal `%{` cannot be written.
   - Every error is a compile error at the offending catalog value, with a fixed problem text and a remediation: an invalid code, a locale declared twice, an invalid or reserved key, interpolated text, a key the default locale lacks, different placeholders, a different kind of value, a missing or unused plural form, a language without plural rules, an unknown framework key, an unsupported time directive, a malformed separator or name list, and a missing or unknown default.
   - Each locale must have the default locale's keys, with the same placeholders. A missing key uses the default locale's text, and the application's `translations` command lists it.
4. **What `Caramel.locales` writes:**
   - **`Caramel::Locale`**, an enum of the declared locales. It answers each locale's code, name, writing direction, plural category, number separators, month and day names, AM and PM, and time patterns. Each piece of formatting data falls back from the locale to the default locale, and then to English.
   - **`Caramel::Messages`**, a struct per catalog group, which `t` returns. Each message is a method whose `case` over the locale has a branch per locale. A message with placeholders takes them as named arguments, and a plural takes its count first.
   - **`Caramel::I18n::TimeFormat`**, `PREFIX` and `MISSING`.
   - **The redefinitions of every framework message some catalog translates.** Each has the hook's signature and answers the request locale's text, else the default locale's, else the English one through `previous_def`.
5. **Plural rules** (`src/caramel/i18n/plural.cr`) are CLDR 47's cardinal rules for whole numbers, one method per family of languages. A plural message must define its family's integer categories, and may define its other categories and exact `=N` counts. The table was checked against CLDR 47's `supplemental/plurals.json` for every listed language, at every count from 0 to 2,999 and around multiples of a million, and matched it everywhere.
6. **Composition and escaping.** A message with placeholders is built by `Caramel::I18n.compose`. When an argument is a `Caramel::HTML::Safe`, the message is safe HTML: the catalog's text and every other argument are escaped, and the safe argument is written as it is. Otherwise the message is plain text, which views escape. Translators never write HTML.
7. **Resolution** (`Application#localized`, `src/caramel/i18n/localized.cr`):
   - With `prefix: true`, a first path segment that is a non-default locale's lowercase code selects that locale and is removed before routing. The default locale has no prefix.
   - A GET or HEAD with a `locale` parameter that names a declared locale is answered without routing: a 303 to the same page in that locale, or 200 with `HX-Redirect` for htmx. Both set the `__Host-caramel_locale` cookie for a year. An unknown value is ignored.
   - Otherwise the locale is the prefix's, else the cookie's, else the best `Accept-Language` match, else the default. An `Accept-Language` longer than 1,024 bytes is ignored, and only its first 16 ranges are read. A range matches its exact tag, then the first locale in its language.
   - Routing runs inside `Caramel::I18n.with`, which binds the locale to the fiber and restores it afterwards. Every response says `Content-Language`. A negotiated response adds `Vary: Accept-Language, Cookie`. A prefix locale that differs from the cookie updates it.
   - Streamed bodies run in the response's locale.
   - `handle` secures every response the hook returns, the switch's redirect included.
8. **Framework messages render when they are created.** Errors keep their `Hash(String, Array(String))` shape, and JSON clients receive localized text. A message created outside a request, such as in a job or a console, is in the default locale unless it is wrapped in `Caramel::I18n.with`. `spawn`ed fibers and Cold Brew jobs start in the default locale: a job carries `param locale : String` and wraps its work in `Caramel::I18n.with`.
9. **Frappé:**
   - `frappe make locale CODE` writes `app/locales/CODE.cr`. The first time, it also writes `app/locales/en.cr` and the i18n lines in `config/application.cr`.
   - After that, `frappe make resource` writes `t.` calls in place of English, and inserts the resource's messages into the default locale's catalog. In such an application it refuses a field or plural that would be an invalid catalog key.
   - `frappe translations` runs the application's `translations` command, which lists each `MISSING code key file` and exits 1 while any key is missing.

## Reasons

- Rendering at creation time, rather than storing error codes, keeps the error hash and the JSON shape every client already reads. Switching to codes would break both, so it waits for a later, breaking release if the owner wants it.
- Hooks that already exist with English and identity bodies let one opt-in require replace them. A plain application keeps exactly its old behaviour, and the check proves its binary holds no i18n code.
- Typed message methods turn a missing or misspelled key, a missing placeholder and a missing plural form into compile errors. An unused message is never typed, so it adds nothing to the binary.

Alternatives the owner rejected:

- YAML catalogs read through a `{{ run }}` macro, which adds a compile step and moves errors away from the catalog's line.
- Code generated by Frappé, which can drift from the catalogs it was generated from.
- Bundled CLDR formatting data, which would add size to every localized binary. Catalogs supply what each application uses, and English is built in.
- Applications that are internationalization-ready from their first day, which would make every application pay for i18n.

Not part of this decision, each a separate feature: select and gender messages, currency and relative time, translated URL segments, translations stored in the database, carrying the locale into Cold Brew jobs automatically, and a report of unused keys.

## Verification

- `scripts/check i18n`:
  - type-checks a valid fixture and one fixture per compile error in `spec/fixtures/i18n`, and asserts each problem text and the fixture's file in the compiler's output;
  - builds the same application without and with `caramel/i18n`, and fails with "i18n code must be absent from an application that does not require caramel/i18n" unless only the second binary holds `__Host-caramel_locale`; the first must answer `200 -` and `404 -`, the second `200 fr` and `404 fr`;
  - runs `spec/i18n`, which covers messages, fallbacks, escaping, plurals in English, Russian and Arabic, negotiation, prefixes, the switch, streaming, translated contract and changeset errors, and number and time formats.
  
  Those specs replace framework methods for their whole program, so they are not part of the main spec run.
- `spec/frappe/locale_generator_spec.cr` and `spec/frappe/resource_generator_spec.cr` cover `frappe make locale` and localized resources. Plain resources are byte-identical to before.
- `scripts/check frappe-project` runs `frappe make locale fr` in a generated application. It then generates localized resources beside a plain one, compiles, lints and specs them, and asserts that `frappe translations` lists fr's missing keys.

## Implementation

- Hooks: `src/caramel/wording.cr`, `src/sugar_orm/wording.cr`, `src/caramel/application.cr` (`route`, `localized`, `streaming`), `src/caramel/http/paths.cr`, `src/caramel/view.cr` (`markup`), `src/caramel/command_line.cr` (`translations`), and the layout template's `html lang: Caramel.language`.
- `caramel/i18n`: `src/caramel/i18n.cr`, `src/caramel/i18n/keys.cr`, `plural.cr`, `catalog.cr`, `runtime.cr` and `localized.cr`.
- Frappé: `src/frappe/publication.cr`, `src/frappe/locale_generator.cr`, `src/frappe/resource_generator.cr`, `src/frappe/commands.cr`, `src/frappe/cli.cr` and `templates/resource`.
- Checks: `scripts/checks/i18n.cr`, `spec/i18n`, `spec/fixtures/i18n` and `scripts/checks/frappe_project.cr`.
