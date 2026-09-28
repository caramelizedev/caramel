# Escaped view notes

Caramel views are Blueprint classes ([ADR 0018](../decisions/0018-blueprint-views.md)).
Every text value and every attribute value a view writes passes through the
five-character HTML escape: `&`, `<`, `>`, double quotes, and single quotes.
The stdlib `HTML.escape` and `Caramel::HTML.escape` escape the same set.
Element and attribute names are written by the view's own code. A caller opts
into trusted markup with an explicit `Caramel::HTML::Safe.new(...)` or
Blueprint's `safe(...)`; both are written as-is, in text and in attribute
values.

Blueprint 1.1.0 escaped only `"` in attribute values, so `&` reached the
browser raw and a stored `&amp;` came back as `&`. It also rendered
attributes through a process-wide cache keyed by their 64-bit hash, never
evicted and locked only under `-Dpreview_mt`. `src/caramel/view.cr` reopens
`Blueprint::HTML::AttributesRenderer` to escape attribute values like text
and to render attributes per call. The patch replaces Blueprint internals, so
the dependency is pinned exactly and `spec/caramel/view_spec.cr` guards it.

The escaping contract covers HTML text and quoted HTML attribute values. It is
not a policy for JavaScript, CSS, or URL contexts. Values used in those
contexts need their own validation or encoding policy before being marked
trusted or rendered.

Views are ordinary Crystal classes with typed constructor arguments. An
unknown method or a wrong type is reported as a Crystal compiler error at the
view's own file, line and column.
