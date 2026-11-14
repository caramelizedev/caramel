# ADR 0024: Internationalization is built in, entered through one require, with catalogs the compiler checks

Date: 2026-10-02

Status: accepted.

## Context

Internationalization is built in. An application that never opts in pays nothing: no per-request work, no allocation, no added binary code and no extra compile step.

## Decision

1. **Core holds hooks with English and identity defaults.** Every framework message comes from a method that returns its English text. The request's language, the localization of a path and the wrapping of a request are hooks that do nothing in a plain application.
2. **One require is the only way in.** Core does not require the implementation, so a plain application does not compile it. The require redefines the hooks. A program that requires it without declaring its locales does not compile.
3. **A catalog is a Crystal literal that the compiler checks.** Catalogs are source files of the application, read with no helper program and no build step. Every catalog mistake is a compile error at the offending catalog value.
4. **A locale may omit keys, and never adds one.** A missing key uses the default locale's text, and a command of the application lists the gaps. A key a locale defines must exist in the default locale with the same kind of value and the same placeholders.
5. **Declaring the locales writes typed code by macro.** The declared locales become an enum. Each message becomes a typed method, with its placeholders as arguments. A framework message that a catalog translates redefines its hook and falls back to the default locale, then to English.
6. **A reserved catalog section carries formatting data and the framework's messages.** A locale supplies its own month names, separators, date patterns and translations of the framework's texts there (`site#c-i18n-reference`). Core ships English only.
7. **Plural rules are CLDR's cardinal rules for whole numbers, built in.** There is one rule per family of languages. A locale whose language has no built-in rule names a language whose rule it uses.
8. **A message is plain text unless it is given safe HTML.** A placeholder's value is escaped. The result is safe HTML only when a value passed to it is.
9. **The request's locale is resolved around routing and bound to the fiber.** It is the path prefix's, else the cookie's, else the best `Accept-Language` match, else the default. Routing and streamed bodies run inside that binding. Generated resource paths carry the request's prefix.
10. **Framework messages render when they are created.** Validation errors keep their shape, and JSON clients receive localized text. Work outside a request, such as a spawned fiber or a background job, uses the default locale unless it binds one itself.
11. **Frappé turns internationalization on, and generated applications start in plain English.** One Frappé command adds the first locale and the opt-in lines. From then on generated resources call typed messages and add their texts to the default catalog.

## Reasons

- Catalogs as Crystal literals and typed message methods make every catalog mistake a compile error on the catalog's line. A message nothing calls adds nothing to the binary.
- Hooks that one opt-in require replaces keep a plain application unchanged and free of i18n code.
- Falling back to the default locale and reporting gaps never blocks shipping.
- Rendering at creation keeps the error hash and the JSON shape that clients read.
- Escaping by default, a per-request locale and localized form URLs avoid injection, races and POST-to-GET redirects.
- Rejected: YAML catalogs through a `{{ run }}` macro, because they add a compile step and move errors off the catalog's line.
- Rejected: Frappé-generated code, because it drifts.
- Rejected: bundled CLDR formatting data, because it enlarges every localized binary.
- Rejected: i18n-ready applications from day one, because all would pay.
