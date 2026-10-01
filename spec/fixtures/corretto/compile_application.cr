require "../../../src/caramel"

{% if @top_level.has_constant?(:Lexbor) %}
  {% raise "Ordinary application builds must not load Lexbor" %}
{% end %}
