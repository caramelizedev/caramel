require "./support/harness"

# caramel/sweet_talk (ADRs 0030, 0031 and 0033). Each declaration mistake fails to compile
# with a fixed problem text, naming its file where the mistake has a line; a valid
# domain compiles, with and without caramel/tenancy; and an application that does not
# require caramel/sweet_talk holds none of its code. spec/sweet_talk and
# spec/sweet_talk_tenancy need PostgreSQL, so scripts/check integration runs them.

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
  {"event_reserved_flow", "event Placed cannot have a field named flow_id: SweetTalk records it"},
  {"event_union_field",
   "an event field may be nilable, as in reason : String?, but not a union of other types"},
  {"cycle_without_boot", "the context map runs in a circle of dependencies through"},
  {"bound_not_literal",
   "value Tins checks its bounds in the database too, so each is an integer literal, as in " \
   "at_least: 0 or length: 3..254, not LEAST: write the number, or add database_check: false"},
  {"length_not_literal",
   "value Code checks its bounds in the database too, so each is an integer literal, as in " \
   "at_least: 0 or length: 3..254, not SHORT: write the number, or add database_check: false"},
  {"database_check_true",
   "value Tins takes database_check: false, which keeps its bounds in Crystal only, not " \
   "database_check: true"},
  {"composite_database_check",
   "value Size has parts, so database_check: false belongs on the values its parts wrap"},
  {"check_name_long",
   "has maximum_temperature_reading : Celsius would check maximum_temperature_reading as " \
   "check_warehousing_refrigerated_shipping_containers_maximum_temperature_reading, longer " \
   "than PostgreSQL's 63 bytes: shorten the attribute, or give Celsius database_check: false"},
  {"table_taken",
   "aggregate TeaTin would store its rows in store_tea_tins, already the table of entity " \
   "Tea::Tin: rename one of them"},
  {"central_not_true",
   "context Catalogue takes central: true, which shares its rows between tenants, not " \
   "central: :yes"},
  {"central_without_tenancy",
   "context Catalogue takes central: true only in a program that requires caramel/tenancy"},
  {"tenant_unnamed",
   "Shop uses SweetTalk in a program that requires caramel/tenancy: name the tenant before " \
   "its contexts"},
  {"tenant_after_context",
   "tenant Account comes after context Catalogue: name the tenant before the contexts"},
  {"tenant_without_tenancy", "tenant Account needs require \"caramel/tenancy\" before this domain"},
  {"tenant_not_schema", "tenant Catalogue must name a SugarORM schema declared before it"},
  {"tenant_twice", "tenant Account is named twice in Shop: keep one"},
  {"tenant_mismatch", "names Shop::Org, but the routes declare Fixture::Account as the tenant"},
  {"central_has_tenanted",
   "has order : Ordering::Order would point from central context Reporting at rows that " \
   "belong to one tenant"},
  {"central_event_tenanted_handler",
   "whenever Catalogue::Tea::Renamed in Names: Catalogue is central, so its events carry no " \
   "tenant"},
  {"channel_long",
   "event TemperatureReadingRecorded's channel " \
   "sweettalk.warehousing.refrigerated_shipping_container.temperature_reading_recorded is " \
   "longer than PostgreSQL's 63 characters"},
  {"channel_tenant_budget",
   "event TemperatureRecorded's channel sweettalk.warehousing.cold_container." \
   "temperature_recorded is longer than 42 characters"},
  {"tenant_index_long",
   "aggregate RefrigeratedShippingContainer would store its rows in " \
   "warehousing_refrigerated_shipping_containers, whose tenant index " \
   "index_warehousing_refrigerated_shipping_containers_on_account_id_and_id is longer than " \
   "PostgreSQL's 63 bytes"},
  {"reference_index_long",
   "has destination_warehouse : Warehouse would index destination_warehouse_id as " \
   "index_warehousing_refrigerated_shipping_containers_on_destination_warehouse_id"},
  {"key_index_long",
   "key refrigerated_container_serial_number : Int64 would index its key as " \
   "index_warehousing_container_readings_on_refrigerated_container_serial_number, longer " \
   "than PostgreSQL's 63 bytes: shorten the key"},
  {"tenant_column_taken",
   "has account : Account would store account_id, the column that names each row's tenant " \
   "Shop::Account"},
  {"tenant_parent_column",
   "entity Charge would name its aggregate in account_id, the column that names each row's " \
   "tenant Shop::Account: rename aggregate Account"},
  {"job_alias_taken",
   "Shop::Pantry::Larder::WhenBlendRefilled claims \"Shop::Pantry::Larder::WhenBlendRestocked\" " \
   "in renamed_from, but Shop::Pantry::Larder::WhenBlendRestocked is a job of that name"},
  {"composite_field", "unsupported Caramel::RequestContract field type: Ordering::Address"},
  {"specification_entities", "specification Empty cannot filter on lines, a list of entities"},
  {"specification_block",
   "specification Empty takes where:, which SweetTalk reads in Crystal and in PostgreSQL " \
   "alike, not a block"},
  {"specification_derived",
   "specification Big filters on size, which Order does not have; it has member, state"},
  {"specification_unknown_state",
   "specification Gone asks for state shipped, which Order does not have"},
  {"specification_predicate_taken",
   "specification Placed would define Order#placed?, which Order already has"},
  {"specification_joins_unknown",
   "specification Overdue joins Late, which is not a specification on Order declared before it"},
  {"specification_without_on",
   "specification Open needs on: an aggregate of Ordering declared before it"},
  {"specification_in_aggregate",
   "specification belongs in a context, after its aggregate, not in aggregate Order"},
  {"specification_state_without_moves",
   "specification Dispatchable filters on state, which Order does not have; it has member"},
  {"specification_without_meaning",
   "Shop::Ordering::Gone needs a meaning: add means: \"…\", the line its glossary entry shows"},
  {"specification_not_a_where",
   "specification Odd takes where: {attribute: value}, or specifications on Order joined by &, " \
   "| and !"},
  {"specification_value_type",
   "no overload matches 'Rules::Shelf::Rows::Jar::QueryOf(NamedTuple())#where', count: String"},
  {"all_satisfying_other",
   "Order.all(satisfying: Shop::Ordering::Gone) takes a specification on Order"},
]
# These problems come from whole-program checks, so they name no fixture line.
UNLOCATED = %w[compile_foreign_name compile_context_cycle compile_cycle_without_boot
  compile_unknown_border compile_each_not_list compile_event_union_field
  compile_rows_named compile_tenant_unnamed compile_central_event_tenanted_handler
  compile_job_alias_taken compile_all_satisfying_other]

cases = {"compile_valid" => nil, "compile_with_tenancy" => nil} of String => String?
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
