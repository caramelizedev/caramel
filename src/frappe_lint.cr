# `frappe lint`: Ameba 1.7.0's rules plus Caramel's rules for RFC-0008
# (ADR 0017). Built separately into bin/frappe-lint by scripts/build-lint.
require "ameba/cli/cmd"
require "./frappe/lint/*"

{% if Fiber.has_constant?(:ExecutionContext) %}
  Fiber::ExecutionContext.default.resize(Fiber::ExecutionContext.default_workers_count)
{% end %}

begin
  exit Ameba::CLI.run ? 0 : 1
rescue ex
  STDERR.puts "Error: #{ex.message}"
  exit 255
end
