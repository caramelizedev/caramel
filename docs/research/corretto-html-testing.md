# Corretto HTML: production cases and authoring evaluation

This inventory selects cases from ordinary forms, catalogs, localized content
and htmx responses. Priority reflects the chance of an incorrect assertion or
broken request workflow; it is not a measurement of production frequency.
Parser fixtures deliberately use raw HTML where source syntax is the behavior
under test. Functional workflows render real Blueprint views through Caramel's
router, contracts, actions and Corretto client. Expectations record independent
requirements rather than calling those views to build expected output.

## Production case inventory

| Priority | Common scenario | Required behavior | Coverage |
|---|---|---|---|
| High | Quantities, prices and identifiers returned as numbers | `small { copies }` checks actual text; a wrong number fails | Authoring; workflows |
| High | Dates or objects accidentally returned from leaf blocks | Require explicit `.to_s`; unsupported values raise even with negation | Authoring |
| High | Escaped customer names, titles and literal entity spellings | Decode once; literal markup stays text; executable markup fails | Existing matcher; production; workflows |
| High | Several forms with hidden CSRF and method fields | Related controls and button belong to one form | Production; workflows |
| High | Unchecked, disabled and required controls | Boolean presence decides state even when the source value says `false` | Production; workflows |
| High | ARIA expansion and JSON/data flags | String `"false"` checks a value; Boolean `false` checks absence | Authoring; workflows |
| High | Conditional CSS arrays with nested arrays and `nil` | Flatten classes and omit `nil`, preserving token matching | Authoring |
| High | Several records contain similar labels | Nested requirements cannot combine unrelated records | Existing matcher; workflows |
| High | Several partials share a target or have different swaps | Target, swap and complete content come from one envelope | Production; workflows; partial contexts |
| High | htmx appends a raw table row or replaces cells | Preserve table payloads inside partial envelopes | Partial contexts |
| Medium | Dropdowns use optional option endings and optgroups | Preserve selected state, separate options and group ancestry | Production; workflows |
| Medium | HTML omits list/description end tags | Inspect the separate nodes the browser constructs | Production |
| Medium | Tables omit `tbody` | Strict mode sees the browser-inserted `tbody` | Production |
| Medium | Table, cell, column and select fragments have leading comments | Choose fragment context without dropping rows or columns | Production; partial contexts |
| Medium | Invalid paragraph nesting is repaired by the browser | Match repaired DOM ancestry rather than source indentation | Production |
| Medium | Pagination links contain `&`, percent escapes and filters | Decode HTML entities without URL-decoding query values | Production; workflows |
| Medium | htmx attributes contain escaped JSON | Compare the original literal JSON attribute value | Production |
| Medium | Prices use NBSP/narrow NBSP; titles contain accents, CJK or emoji | Preserve meaningful Unicode and nonbreaking spaces | Production |
| Medium | A textarea receives Windows newlines or a leading newline | Inspect HTML5-normalized DOM text; preserve remaining whitespace | Production |
| Medium | Build/cache comments split otherwise adjacent text | `plain` joins direct text across comments, never across elements | Authoring; production |
| Medium | Pretty and minified mixed content differ in formatting | Strict `plain`/element requirements behave consistently | Production |
| Medium | CSS scopes overlap or a card only partly satisfies a pattern | Deduplicate roots; count complete matches | Production |
| Medium | An inert template contains rows resembling visible records | Its content cannot satisfy visible DOM requirements | Production |
| Medium | A failure is followed by a corrected request or reused matcher | Clear counts and diagnostics; no freed native node survives | Authoring; workflows |
| Medium | A typo, empty expectation or invalid/missing scope is used with negation | Raise a clear error rather than pass silently | Existing matcher; compiler fixtures |

Coverage names refer to:

- `spec/corretto/html_spec.cr`: the original matching contract and escaping mutations.
- `spec/corretto/html_authoring_spec.cr`: scalar values, conditional classes,
  direct text, matcher reuse and retained diagnostics.
- `spec/corretto/html_production_spec.cr`: browser parsing, forms, localization,
  URLs, counts, mixed content and batched partial identity.
- `spec/corretto/html_partial_context_spec.cr`: protocol envelope parsing.
- `spec/corretto/html_native_spec.cr`: binding sizes, offsets and enum values
  checked against the actual pinned C source with the native compiler.
- `spec/corretto/html_workflow_spec.cr`: real application request workflows.
- `spec/corretto/mocking_spec.cr`: vocabulary/type checks and parser isolation.

## Functional authoring exercise

The seven workflows use `spec/fixtures/corretto/html_workflow_app.cr`, a small
order application. They exercise authoring and diagnosis through executable
specs; this evaluation did not recruit human participants or test browser clicks.

| Task | Observed result |
|---|---|
| Describe a rendered form with captured paths, labels and the client's CSRF token | Familiar element calls express the relevant form requirements together |
| Check native controls plus ARIA/data state | Presence syntax works; literal false values need explicit strings |
| Describe dropdown choices through a Crystal loop | Loops and captured tuples compile; `select_tag` avoids Crystal's `select` keyword |
| Submit invalid quantity, inspect the contract error, then submit a correction | Response status, error region and accepted partial can be checked without raw HTML assertions |
| Submit a title containing markup, accents and a literal `&amp;` | Decoded content stays literal and belongs to the intended partial target |
| Describe several rendered records using local tuples | Loops remain concise; numeric blocks now check quantities instead of silently omitting text |
| Intentionally expect the wrong quantity and correct the assertion | Diagnostics identify the nested path, expected/observed text, count and relevant HTML |

## Findings and decisions

The evaluation exposed silent scalar text checks, incompatible nested class
arrays, comment-split direct text and lost table payloads in partial envelopes.
Each receives a regression and an implementation correction. Numeric, Boolean
and character leaf values now check literal text. Other leaf values require
explicit `.to_s` rather than silently skipping their text checks. Recording
remains independent of Blueprint's renderer. Class arrays follow its authoring
convention, while the parser independently supplies actual class tokens.

Keep the current Boolean attribute convention rather than introduce a separate
rule for every HTML/ARIA/data attribute. The guide now shows `"false"` explicitly.
For mixed content use `plain` between element calls; a returned string describes
aggregate descendant text. Use `strict` only when complete direct structure is
the contract; browser-inserted wrappers are part of that structure.
Distinctness applies per requirement level. Two distinct matched ancestors may
share deeper descendants in selected mode; repeated records should specify
their IDs, while strict mode establishes direct sibling structure.

The partial adapter uses token metadata to rename protocol envelopes before one
HTML5 DOM parse, then restores their parsed content under the original envelope
attributes. This matches htmx's template context even when a title precedes raw
rows. It does not parse HTML itself or expose ordinary inert template contents.
The private native template-content layout is checked against the pinned
Lexbor 3.0.0 C source by a compiler-backed regression on macOS ARM64; a parser
upgrade requires reviewing it. Foreign-namespace envelopes raise a controlled
error before native template access, while HTML inside SVG `foreignObject` works.

## PR review follow-up

After the independent testing and code review, the
[PR review comment](https://github.com/caramelizedev/caramel/pull/18#issuecomment-5923041750)
was read and checked against the evidence:

| Finding | Resolution |
|---|---|
| Numeric text silently omitted | Independently reproduced and fixed; unsupported other leaf values raise with `.to_s` guidance |
| Table rows lost inside partials | Independently reproduced and fixed with htmx-compatible template contexts |
| Serialization and wire assertions weakened | Restored exact bytes for escaping, ordered partials and nested-view output; retained behavioral checks |
| Parser fetched/built for production | Explicit framework/application development dependency; generated-project check verifies production omission and development restoration |
| Nested SVG tag casing inconsistent | Normalize names at nested matching boundaries; positive and negative gradient coverage |
| Overlapping ancestor matches share descendants | Document per-level selected matching; identity attributes and strict direct structure make repeated-record intent explicit |
| Negative partial diagnostics omit content | Include the complete recorded content requirement in the failure description |
| All framework scripts exposed to dependency hooks | Private temporary PATH directory exposes only the current compiler; hook tests cover status, cleanup and old installed launchers |

A real bare-Crystal dependency hook was also exercised with an older installed
toolchain: managed OpenSSL initialization and heap settings worked without
altering that installation. The application template and migration guidance
declare Lexbor 3.6.4 as a development dependency. Frozen production installs
must not install it; development setup must restore it before Corretto runs.

Server DOM assertions do not prove focus behavior, accessibility-tree behavior,
JavaScript execution or actual htmx morphing. Existing browser checks retain that
boundary. No new snapshot comparison or expected-view rendering is needed.

## Primary references

- [HTML Boolean attributes](https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#boolean-attributes)
  define presence and absence semantics.
- [WAI-ARIA expanded state](https://www.w3.org/TR/wai-aria-1.2/#aria-expanded)
  describes the explicit `true` and `false` values used by widgets.
- [htmx partials](https://htmx.org/attributes/hx-partial/)
  describe batched envelopes and template conversion that preserves table payloads.
- Blueprint 1.1.0's installed `BufferRenderer` and `AttributesRenderer` define
  scalar rendering and conditional class-array authoring conventions. Actual
  expectations continue to record values directly rather than call either renderer.
