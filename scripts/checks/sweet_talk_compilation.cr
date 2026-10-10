require "./support/harness"

# caramel/sweet_talk (ADRs 0030 and 0031). Each declaration mistake fails to compile
# with a fixed problem text, naming its file where the mistake has a line; a valid
# domain compiles; and an application that does not require caramel/sweet_talk holds
# none of its code. spec/sweet_talk needs PostgreSQL, so scripts/check integration runs it.

FIXTURES = "spec/fixtures/sweet_talk"
ABSENT   = "SweetTalk code must be absent from an application that does not require " \
           "caramel/sweet_talk"
# A string only SweetTalk's boundary holds.
MARKER = "a command changes one aggregate"

# Each fixture's problem text, by the fixture's name after `compile_`.
PROBLEMS = [
  {"missing_meaning", "Shop::Catalogue::Tea needs a meaning: add means:"},
  {"foreign_name", "Shop::Ordering names Catalogue:: outside a border"},
  {"context_cycle", "the context map runs in a circle of dependencies through"},
  {"unknown_border", "has a border with Ordring, but there is no context Ordring"},
  {"foreign_event", "emits only its own events"},
  {"unknown_state", "undefined local variable or method 'shipped!'"},
  {"the_without_type", "the total needs a type"},
  {"value_type", "value Grams wraps Int32, Int64 or String, or takes parts, not Float64"},
  {"whenever_in_aggregate", "whenever belongs in a context, a border or a projection"},
  {"hash_attribute", "has teas : Hash(Int64, Int32) cannot be stored: use an entity"},
  {"unsupported_type", "has weight : Float32 cannot be stored"},
  {"projection_without_key", "projection Sales needs a key"},
  {"key_outside_projection", "key belongs in a projection"},
  {"duplicate_handler", "write one whenever per event"},
  {"value_mix", "to 'Shop::Catalogue::Tins#+' to be"},
  {"undeclared_times", "to 'Shop::Catalogue::Cents#*' to be"},
  {"each_not_list",
   "each: :member needs a list, but Order::Placed has no Array field named member"},
  {"rows_named", "Shop::Ordering names Rows, SweetTalk's storage"},
  {"renamed_from_itself", "Tea is renamed_from: Tea, its own name"},
  {"event_loads_nothing", "undefined method 'order' for Shop::Ordering::Order::Placed"},
  {"service_in_aggregate", "service belongs in a context, not in aggregate Order"},
  {"factory_unset_attribute",
   "factory open does not set member: take member : String, or give has member a default"},
  {"factory_repository_name",
   "factory find would replace Order.find: name it for what it makes, as in factory open"},
  {"create_beside_factory", "undefined method 'create' for Shop::Ordering::Order.class"},
  {"finds_unknown_attribute",
   "finds of filters on membr, which Order does not have; it has member, state"},
  {"finds_unknown_state",
   "finds of asks for state shipping, which Order does not have; states: open, placed"},
  {"finds_entities", "finds of cannot filter on lines, a list of entities"},
  {"value_string_bounds",
   "value Email wraps String, so it takes matches: and length:, not at_least:"},
  {"value_int_matches",
   "value Tins wraps Int32, so it takes at_least:, at_most:, within: and times:, not matches:"},
  {"composite_part_type",
   "part weight : Float32 cannot be stored: a part is String, Int32, Int64, Bool, Float64, Time " \
   "or a value that wraps one"},
  {"composite_without_parts", "value Address needs parts, as in part street : String"},
  {"process_without_key",
   "process Hold needs a key, as in key slot : Slot, the attribute that picks its row"},
  {"process_whenever_without_key",
   "whenever Order::Placed in process Hold needs key:, the expression that picks its row"},
  {"process_attribute_default",
   "has tins : Int32 in process Hold needs a literal default, as in has tins : Int32 = 0: its " \
   "row starts from its key alone"},
  {"compensate_without_whenever",
   "compensate Order::Placed needs a whenever Order::Placed before it in Ordering"},
  {"compensate_in_projection",
   "compensate belongs beside a whenever in a context, a border or a process, not in projection " \
   "Sales"},
  {"arm_unknown_deadline", "arm lapsee names no deadline of Hold; deadlines: lapse"},
  {"deadline_outside_process", "deadline belongs in a process, not in aggregate Order"},
  {"event_reserved_field", "event Placed cannot have a field named actor: SweetTalk records it"},
  {"event_union_field",
   "an event field may be nilable, as in reason : String?, but not a union of other types"},
  {"cycle_without_boot", "the context map runs in a circle of dependencies through"},
]
# These problems come from whole-program checks, so they name no fixture line.
UNLOCATED = %w[compile_foreign_name compile_context_cycle compile_cycle_without_boot
  compile_unknown_border compile_each_not_list compile_event_union_field
  compile_rows_named]

cases = {"compile_valid" => nil} of String => String?
PROBLEMS.each { |(name, problem)| cases["compile_#{name}"] = problem }

sources = cases.keys.map { |name| "#{FIXTURES}/#{name}.cr" }
results = Caramel::Checks.type_check(sources)
cases.each_with_index do |(name, problem), index|
  result = results[index]
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  if problem
    Caramel::Checks.fail(output) if result.success?
    required = [problem]
    required << "#{name}.cr:" unless UNLOCATED.includes?(name)
    missing = required.find { |text| !result.stderr.includes?(text) }
    Caramel::Checks.fail("missing #{missing.inspect} in #{output}") if missing
  else
    Caramel::Checks.fail(output) unless result.success?
  end
  puts "PASS: #{name}"
end

# The same application without and with caramel/sweet_talk: only the second holds
# its code, and both run alike.
root = Caramel::Checks.private_temp("caramel-sweet-talk-")
at_exit { FileUtils.rm_rf(root) }
{"plain", "sweet"}.each do |name|
  binary = File.join(root, name)
  build = Caramel::Checks.crystal(["build", "#{FIXTURES}/#{name}.cr", "-o", binary],
    timeout: 1.hour)
  Caramel::Checks.fail(build.stdout + build.stderr) unless build.success?
  present = File.read(binary).includes?(MARKER)
  Caramel::Checks.fail(ABSENT) unless present == (name == "sweet")
  ran = Caramel::Checks.run([binary], timeout: 1.minute)
  unless ran.success? && ran.stdout == "#{name}\n"
    Caramel::Checks.fail("#{name} printed:\n#{ran.stdout}#{ran.stderr}")
  end
end
puts "PASS: an application without caramel/sweet_talk holds none of its code, " \
     "and both run alike"
