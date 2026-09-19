require "../../../src/caramel/form_input"

module Admin
  struct OrderLineInput
    include Caramel::FormInput
    field title : String
    field quantity : Int32
    field note : String?
  end
end
