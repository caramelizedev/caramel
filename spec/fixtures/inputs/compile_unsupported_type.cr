require "../../../src/caramel/form_input"

struct UnsupportedInput
  include Caramel::FormInput
  field titles : Array(String)
end
