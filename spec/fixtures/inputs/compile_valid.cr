require "./declared_input"

input = Admin::OrderLineInput.new(title: "Item", quantity: 2)
form = Caramel::Form.new("order_line[title]=Item&order_line[quantity]=3", Admin::OrderLineInput.envelope, Admin::OrderLineInput.fields, Admin::OrderLineInput.required_fields)
result = Admin::OrderLineInput.from_form(form)
puts input.title, result.value.try(&.quantity)
