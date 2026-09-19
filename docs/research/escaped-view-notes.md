# Escaped view notes

Caramel's compiled ECR views pass every ordinary `<%= ... %>` expression through
`Caramel::HTML.escape`. The helper escapes `<`, `>`, `&`, double quotes, and
single quotes. Literal template text is emitted as authored. A caller can opt
into trusted markup with an explicit `Caramel::HTML::Safe.new(...)`; the view
compiler sends that value through the trusted overload exactly once.

The escaping contract covers HTML text and quoted HTML attribute values. It is
not a policy for JavaScript, CSS, or URL contexts. Values used in those
contexts need their own validation or encoding policy before being marked
trusted or rendered.

Templates are compiled at Crystal compile time. Expressions resolve in the
caller's lexical scope, so an unknown local is reported as a Crystal compiler
error with the template path and source location preserved.
