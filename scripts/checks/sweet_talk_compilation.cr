require "./support/harness"

# caramel/sweet_talk (ADRs 0030, 0031, 0033, 0034 to 0036, 0039 to 0041 and 0043 to 0048). Each
# declaration mistake fails to compile with a fixed problem text, naming its file where the
# mistake has a line; a valid domain compiles, with and without caramel/tenancy; and an
# application that does not require caramel/sweet_talk holds none of its code. spec/sweet_talk
# and spec/sweet_talk_tenancy need PostgreSQL, so scripts/check integration runs them.

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
  {"value_type",
   "value Grams wraps Int32, Int64, String, Date, Decimal(P, S) or Json(T), or takes parts, " \
   "not Float64"},
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
   "value Email wraps String, so it takes matches:, length: and one_of:, not at_least:"},
  {"value_int_matches",
   "value Tins wraps Int32, so it takes at_least:, at_most:, within: and times:, not matches:"},
  {"value_int_one_of",
   "value Tins wraps Int32, so it takes at_least:, at_most:, within: and times:, not one_of:"},
  {"date_option",
   "value Day wraps Date, a real calendar day, so it takes no at_least:"},
  {"date_database_check",
   "value Day wraps Date, a real calendar day, so it takes no database_check:"},
  {"day_today", "undefined method 'today' for Shop::Ordering::Day.class"},
  {"day_plus_day", "expected argument #1 to 'Shop::Ordering::Day#+' to be Int, not " \
                   "Shop::Ordering::Day"},
  {"day_query_text",
   "no overload matches 'Shop::Ordering::Rows::Parcel::QueryOf(NamedTuple())#where', " \
   "shipped_on: Range(String, String)"},
  {"one_of_not_list",
   "value Roast takes one_of: a list of words, as in one_of: %w[payment receipt], not \"light\""},
  {"one_of_with_matches",
   "value Roast lists its members with one_of:, so it takes neither matches: nor length:"},
  {"one_of_word",
   "value Roast lists dark-roast in one_of:, which is not a word of letters, digits and " \
   "underscores that starts with a letter"},
  {"one_of_duplicate",
   "value Roast lists light twice in one_of:, and each member names Roast.light and Roast#light?"},
  {"one_of_reserved",
   "value Roast lists all in one_of:, which would define Roast.all and Roast#all?, names Roast " \
   "already has: choose another word"},
  {"one_of_class_method",
   "value Roast lists name in one_of:, which would define Roast.name and Roast#name?, names " \
   "Roast already has: choose another word"},
  {"one_of_object_method",
   "value Roast lists inspect in one_of:, which would define Roast.inspect and Roast#inspect?, " \
   "names Roast already has: choose another word"},
  {"one_of_keyword",
   "value Roast lists end in one_of:, which would define Roast.end and Roast#end?, names " \
   "Roast already has: choose another word"},
  {"key_optional", "key tea cannot be optional: every row has its key"},
  {"stray_reference_write",
   "choose assigns @tea, but tea is a reference stored as tea_id: use self.tea = ..., which " \
   "takes the aggregate, the record or its id"},
  {"stray_reference_write_factory",
   "open assigns @tea, but tea is a reference stored as tea_id: use self.tea = ..., which " \
   "takes the aggregate, the record or its id"},
  {"stray_reference_write_process",
   "whenever Order::Placed assigns @first_tea, but first_tea is a reference stored as " \
   "first_tea_id: use self.first_tea = ..., which takes the aggregate, the record or its id"},
  {"stray_reference_write_multiple",
   "choose assigns @tea, but tea is a reference stored as tea_id: use self.tea = ..., which " \
   "takes the aggregate, the record or its id"},
  {"projection_key_write", "undefined method 'tea=' for Shop::Ordering::Sales"},
  {"where_nil_required_scalar",
   "unnoted asks for note: nil, but note is not optional: nil is a value of an optional " \
   "attribute, as in has note : String?"},
  {"where_nil_required_composite",
   "without_total asks for total: nil, but total is not optional: nil is a value of an " \
   "optional attribute, as in has total : Money?"},
  {"where_nil_required_specification",
   "specification Unnoted asks for note: nil, but note is not optional: nil is a value of an " \
   "optional attribute, as in has note : String?"},
  {"emit_carried_field",
   "emit Noted gives note, which the event carries from Order: it is read from the aggregate, " \
   "so an event cannot say what the aggregate does not hold"},
  {"event_carries_not_list",
   "event Placed takes carries: a list of Order's attributes or derived values, as in carries: " \
   "[member, total], not member"},
  {"event_carries_unknown",
   "event Placed carries membr, which Order does not have above it; it has member: declare " \
   "membr before the event"},
  {"event_carries_twice",
   "event Placed has a field named member twice: carry it, or declare it, not both"},
  {"event_carries_reserved",
   "event Placed cannot have a field named actor: SweetTalk records it"},
  {"composite_part_type",
   "part weight : Float32 cannot be stored: a part is String, Int32, Int64, Bool, Float64, Time " \
   "or a value that wraps one"},
  {"composite_without_parts", "value Address needs parts, as in part street : String"},
  {"process_without_key",
   "process Hold needs a key, as in key slot : Slot, the attribute that picks its row"},
  {"process_whenever_without_key",
   "whenever Order::Placed in process Hold needs key:, the expression that picks its row"},
  {"process_attribute_default",
   "has tins : Int32 in process Hold needs a literal default, as in has tins : Int32 = 0, or " \
   "a value built from one, as in has total : Cents = Cents.new(0): its row starts from its " \
   "key alone"},
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
  {"tenant_column_taken",
   "has account : Account would store account_id, which names each row's tenant " \
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
  {"state_check_long",
   "moves would check RefrigeratedShippingContainer's states as " \
   "check_warehousing_refrigerated_shipping_containers_state_eb99943a, longer than " \
   "PostgreSQL's 63 bytes"},
  {"finds_block_count",
   "finds how_many narrows jars with where, where_null, order_by, limit and offset only, so " \
   "it reads Jar rows and writes nothing, not count"},
  {"finds_block_delete",
   "finds purge narrows jars with where, where_null, order_by, limit and offset only, so it " \
   "reads Jar rows and writes nothing, not delete_all"},
  {"finds_block_rows", "Rules::Shelf names Rows, SweetTalk's storage"},
  {"finds_block_sql",
   "finds wiped reads only the rows it is given, so it names neither SugarORM nor its Repo"},
  {"finds_block_and_where",
   "finds newest takes a block, or where:, satisfying:, order: and first:, not both"},
  {"finds_block_two",
   "finds newest takes a block of one expression that narrows the rows it is given"},
  {"finds_unknown_argument",
   "finds first_ten takes where:, satisfying:, order: and first:, or a block, not limit:"},
  {"finds_nothing",
   "finds everything adds nothing to Jar.all: give where:, satisfying:, order: or first:"},
  {"finds_order_unknown",
   "finds newest orders by created, which Jar cannot sort by: order by id, or by an " \
   "attribute stored in one column"},
  {"finds_order_entities", "finds by_slots orders by slots, which Jar cannot sort by"},
  {"finds_order_direction", "finds by_label orders label by :sideways: take :asc or :desc"},
  {"counts_with_order", "counts fullest takes where: and satisfying:, not order:"},
  {"counts_with_block", "counts big takes where: and satisfying:, not a block"},
  {"query_name_taken",
   "Jar already has a query named gifts: give each finds, counts, sums and groups its own name"},
  {"finds_named_all", "finds all would replace Jar.all: name it for what it finds"},
  {"counts_named_all", "counts all would replace Jar.all: name it for what it counts"},
  {"finds_name_taken",
   "Jar already has a query named gifts: give each finds, counts, sums and groups its own name"},
  {"sums_without_of",
   "sums grams_total takes of:, the attribute it adds up, as in of: :total or of: Line.price"},
  {"sums_with_block", "sums grams_total takes of:, where: and satisfying:, not a block"},
  {"sums_unknown_attribute",
   "sums grams_total adds up :weight, which Jar does not have above this line: declare it, a " \
   "stored attribute, before the query"},
  {"sums_foreign_entity",
   "sums grams_total adds up Tin.grams, but Tin is not an entity of Jar declared above this " \
   "line"},
  {"sums_not_number",
   "sums grams_total adds up :label, which is not a number: add up an Int32, Int64 or Float64 " \
   "attribute, or a value that wraps a whole number or a decimal"},
  {"sums_bounded_value",
   "sums grams_total adds up :dose, a Dose, whose bounds a sum can break: add up a value that " \
   "takes 0 and has no upper bound, as in value Cents, Int64, means: \"…\""},
  {"groups_without_by",
   "groups grams_by_tea takes by:, the attribute it groups by, as in by: :state or by: Line.tea"},
  {"groups_by_outside_entity",
   "groups grams_by_tea adds up Slot.grams, so it groups by another attribute of Slot, not " \
   ":label: narrow Jar with where: instead"},
  {"groups_by_ungroupable",
   "groups grams_by_tea groups by Slot.brewed_at, which has no one-column key: group by text, " \
   "a whole number, a Bool, a day, a decimal, an aggregate it refers to, or state"},
  {"finds_where_not_tuple",
   "finds labelled takes where: {attribute: value}, as in where: {member: member, state: " \
   ":placed}"},
  {"counts_where_not_tuple",
   "counts labelled takes where: {attribute: value}, as in where: {member: member, state: " \
   ":placed}"},
  {"finds_order_not_tuple",
   "finds by_label takes order: {attribute: :asc or :desc}, as in order: {id: :desc}"},
  {"finds_satisfying_value", "finds big takes satisfying: a specification on Jar, not Count"},
  {"finds_value_type",
   "no overload matches 'Rules::Shelf::Rows::Jar::QueryOf(NamedTuple())#where', count: String"},
  {"finds_uncalled_unknown_key",
   "finds by_colour filters on colour, which Jar does not have; it has label, count, state"},
  {"loader_outside", "protected method '__sweettalk_rows' called for Rules::Shelf::Jar.class"},
  {"projection_finds_satisfying",
   "finds placed_teas takes satisfying: only in an aggregate: a specification is a rule on " \
   "an aggregate, and Sales is a projection"},
  {"projection_counts_satisfying",
   "counts placed_count takes satisfying: only in an aggregate: a specification is a rule on " \
   "an aggregate, and Sales is a projection"},
  {"projection_finds_state",
   "finds open_teas filters on state, which Sales does not have; it has tea, sold"},
  {"projection_finds_named_all", "finds all would replace Sales.all: name it for what it finds"},
  {"projection_finds_order_unknown",
   "finds newest orders by created, which Sales cannot sort by: order by id, or by an " \
   "attribute stored in one column"},
  {"projection_finds_block_count",
   "finds how_many narrows rows with where, where_null, order_by, limit and offset only, so " \
   "it reads Sales rows and writes nothing, not count"},
  {"subdomain_unknown",
   "context Catalogue takes subdomain: :core, :supporting or :generic, not subdomain: :main"},
  {"unpublished_name",
   "Shop::Ordering names Catalogue::Tea, which Catalogue does not publish; it publishes Cents, " \
   "Tea::Id, price_of: use one of those, or publish Tea in Catalogue"},
  {"unpublished_call",
   "Shop::Ordering calls Catalogue.teas_on_shelf, which Catalogue does not publish"},
  {"unpublished_in_border",
   "Shop::Fulfilment names Catalogue::Tea, which Catalogue does not publish"},
  {"published_after_use",
   "Shop::Reporting names Catalogue::Tea, which Catalogue does not publish"},
  {"publishes_unknown",
   "Catalogue publishes Teas, which it does not declare: declare a type, a service or a unit " \
   "of that name before publishes"},
  {"publishes_expression",
   "publishes takes the context's types, services and units, as in publishes Cents, Tea::Id, " \
   "price_of, not price_of(1)"},
  {"call_outside_border",
   "Shop::Reporting calls Catalogue.teas_on_shelf outside a border: move that call into " \
   "border Catalogue do … end, or declare follows: Catalogue"},
  {"outbound_outside_border",
   "Shop::Billing reaches Caramel::Outbound outside a border with an outside system"},
  {"client_in_context_border",
   "Shop::Billing reaches HTTP::Client outside a border with an outside system"},
  {"outside_is_a_context",
   "Shop::Billing has a border with Catalogue, outside: \"…\", but Catalogue is a context"},
  {"outside_not_text",
   "border Cards takes outside: \"…\", what the system is to this context"},
  {"outside_nil",
   "border Cards takes outside: \"…\", what the system is to this context, the line its " \
   "glossary entry shows"},
  {"whenever_outside",
   "whenever belongs in a border with a context: Cards is outside the program and emits no " \
   "events"},
  {"kernel_without_meaning", "Shop::Money needs a meaning: add means:"},
  {"kernel_shared_by_one",
   "kernel Money takes shared_by: [Pricing, Billing], the two or more contexts or kernels " \
   "that share it, not shared_by: [Catalogue]"},
  {"kernel_holds_service",
   "kernel Money holds values and aggregates only, not service: move it into a context that " \
   "shares Money"},
  {"kernel_outbound",
   "kernel Money reaches Caramel::Outbound, which only a border with an outside system may"},
  {"shares_not_kernel",
   "context Ordering shares Catalogue, which is no kernel declared before it"},
  {"shares_unlisted",
   "context Fulfilment shares Money, but kernel Money is shared by Catalogue, Ordering: add " \
   "Fulfilment to its shared_by:"},
  {"kernel_shares_unlisted",
   "kernel Money shares Calendar, but kernel Calendar is shared by Catalogue, Ordering: add " \
   "Money to its shared_by:"},
  {"kernel_unknown_sharer",
   "Shop::Money is shared by Ordring, but there is no context or kernel Ordring"},
  {"kernel_sharer_silent",
   "Shop::Money is shared by Ordering, but Ordering does not say shares: Money"},
  {"kernel_not_shared", "Shop::Fulfilment names Money::, a kernel it does not share"},
  {"kernel_names_context",
   "Shop::Money is a kernel and names Catalogue: a kernel names no context"},
  {"follows_kernel", "Shop::Fulfilment follows Money, a kernel: say shares: Money"},
  {"border_kernel", "Shop::Fulfilment has a border with Money, a kernel: say shares: Money"},
  {"kernel_word_alone",
   "Shop::Money::Millionths is named only by Catalogue: a kernel holds what two or more of " \
   "its sharers name; move Millionths into Catalogue"},
  {"kernel_word_unused", "Shop::Money::Millionths is named by none of its sharers"},
  {"command_finalize",
   "command finalize would replace the garbage collector's finalize on Run: name it for what " \
   "it does, as in to wind_up"},
  {"has_tenant",
   "has tenant : String would replace Tea#tenant, which names each row's tenant Shop::Account " \
   "on an aggregate of a tenanted context: name the attribute for its role, as in has owner : " \
   "String"},
  {"has_tenant_id",
   "has tenant_id : Int64 would replace Tea#tenant_id, which names each row's tenant " \
   "Shop::Account on an aggregate of a tenanted context: name the attribute for its role, as " \
   "in has owner : Int64"},
  {"process_finds_named_all", "finds all would replace Hold.all: name it for what it finds"},
  {"process_finds_satisfying",
   "finds held takes satisfying: only in an aggregate: a specification is a rule on an " \
   "aggregate, and Hold is a process"},
  {"entity_holds_entities",
   "has slices : Array(Slice) cannot be stored in entity Rule: an entity holds no entities; " \
   "declare Slice beside Rule and key it by Rule's number"},
  {"array_of_scalars",
   "has tags : Array(String) cannot be stored: use a value or an entity; an Array of scalars " \
   "is not stored"},
  {"bool_state_predicate",
   "moves placed would define Order#placed?, which Order already has from has placed : Bool: " \
   "name the state or the attribute for what it means"},
  {"tenant_association_taken",
   "has account : Bool = false would store account, which names each row's tenant " \
   "Shop::Account: name the attribute for its role, as in has owner : Bool"},
  {"parent_column_taken",
   "has tea : Bool = false would store tea, which names the aggregate that holds each Tin: " \
   "name the attribute for its role, as in has owner : Bool"},
  {"projection_composite_default",
   "has deliver_to : Address = Address.new(street: \"\", city: \"\") in projection Sales " \
   "cannot have a default: a value with parts or a calendar day has no SQL default, and its " \
   "row starts from its key alone; make it optional, as in has deliver_to : Address?"},
  {"emit_outside_service",
   "emit belongs in a service body: a context emits Renamed from a service, as in service " \
   "rename(name : String), means: \"…\" do … end, and an aggregate from a command"},
  {"context_event_carries",
   "event Renamed in Catalogue takes no carries:: a context holds no attributes to carry; " \
   "declare the fields it records, as in event Renamed, name : String"},
  {"uncalled_command_body", "undefined local variable or method 'dispatched!'"},
  {"unit_in_aggregate", "unit belongs in a context, not in aggregate Order"},
  {"kernel_holds_unit",
   "kernel Money holds values and aggregates only, not unit: move it into a context that " \
   "shares Money"},
  {"unit_changes_foreign", "Shop::Ordering names Catalogue:: outside a border"},
  {"unit_without_meaning",
   "Shop::Ordering.restock needs a meaning: add means: \"…\", the line its glossary entry shows"},
  {"central_unit_tenanted",
   "unit audit in Reporting, a central context, changes Ordering::Order, whose rows belong " \
   "to a tenant: a central context's unit changes the aggregates of central contexts alone"},
  {"unique_in_projection",
   "unique belongs in an aggregate or an entity, not in projection Sales: its key is its " \
   "identity"},
  {"index_in_process",
   "index belongs in an aggregate or an entity, not in process Tally: its key is its identity"},
  {"has_check_in_projection",
   "check belongs in an aggregate or an entity, not in projection Sales: its key is its " \
   "identity"},
  {"unique_unknown_attribute",
   "unique :code names code, which Crate does not have above it; it has label: declare code " \
   "before the unique"},
  {"index_unknown_attribute",
   "index :label, :state names state, which Crate does not have above it; it has label: " \
   "declare moves, whose state it names, before the index"},
  {"check_without_sentence",
   "check :not_negative needs otherwise:, the sentence a row that breaks it is refused with, " \
   "as in check :not_negative, \"quantity >= 0\", otherwise: \"A pending line carries no " \
   "amounts.\""},
  {"has_check_without_sentence",
   "has quantity : Int32 takes check: {\"sql\", \"sentence\"}, the SQL every row keeps and " \
   "the sentence a row that breaks it is refused with, as in check: {\"quantity >= 0\", " \
   "\"A crate cannot hold less than nothing.\"}"},
  {"unique_entities",
   "has lines : Array(Line) takes no unique:, index: or check:: what makes Line unique, or " \
   "what it keeps, is declared inside entity Line"},
  {"unique_twice", "Crate declares unique :label twice"},
  {"decimal_without_require",
   "value Rate wraps Decimal, which needs require \"caramel/sweet_talk/decimal\" before this " \
   "domain: a program that declares no decimal value never links GMP"},
  {"decimal_bound_scale",
   "value Rate takes at_least: \"0.123456789\", which has more than 8 decimals: Decimal(20, 8) " \
   "keeps 8, so a bound written past them would never hold"},
  {"decimal_bound_not_text",
   "value Rate checks its bounds in the database too, so each is a decimal written as text, " \
   "as in at_least: \"0\" or at_most: \"1.5\", not 0: write it in quotes, or add " \
   "database_check: false"},
  {"json_option",
   "value Evidence wraps Json, a document PostgreSQL keeps whole, so it takes no at_least:"},
  {"json_order",
   "finds by_evidence orders by evidence, a JSON value, which Price cannot sort by: a " \
   "document has no order; order by id, or by an attribute stored in one column"},
  {"json_range",
   "no overload matches 'Shop::Pricing::Rows::Price::QueryOf(NamedTuple())#where', " \
   "evidence: Range(JSON::Any, JSON::Any)"},
  {"projection_decimal_default",
   "has rate : Rate = Rate.new(\"0\") in projection Rates cannot have a default: a decimal or " \
   "a JSON value is stored through its codec, which takes no SQL default, and its row starts " \
   "from its key alone; make it optional, as in has rate : Rate?"},
  {"after_not_following",
   "whenever Order::Placed, after: Sales in Ordering: Sales does not follow Order::Placed; " \
   "after: names a projection, a process or a context with a whenever Order::Placed of its own"},
  {"after_cycle",
   "whenever Order::Placed, after: Sales in Ordering: after: runs in a circle, Ordering → " \
   "Sales → Ordering; one of them follows Order::Placed without after:"},
  {"after_each",
   "whenever Order::Placed, after: Sales in Ordering: Sales handles Order::Placed with each: " \
   "lines, one job per element, which releases no follower; follow the event without after:"},
  {"rebuild_without_log",
   "SweetTalk.rebuild(Shop::Ordering::Sales): Ordering keeps no event log to replay; say " \
   "context Ordering, event_log: true, and rebuild from the events logged since"},
  {"event_log_table_taken",
   "context Ordering keeps its event log in ordering_events, the table aggregate Event stores " \
   "its rows in: rename one of them"},
]
# These problems come from whole-program checks, so they name no fixture line.
UNLOCATED = %w[compile_foreign_name compile_context_cycle compile_cycle_without_boot
  compile_unknown_border compile_each_not_list compile_event_union_field
  compile_rows_named compile_tenant_unnamed compile_central_event_tenanted_handler
  compile_job_alias_taken compile_all_satisfying_other compile_finds_value_type
  compile_day_query_text compile_loader_outside compile_published_after_use
  compile_call_outside_border compile_outside_is_a_context compile_kernel_unknown_sharer
  compile_kernel_sharer_silent compile_kernel_not_shared compile_kernel_names_context
  compile_follows_kernel compile_border_kernel compile_kernel_word_alone
  compile_kernel_word_unused compile_unit_changes_foreign compile_json_range]

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
