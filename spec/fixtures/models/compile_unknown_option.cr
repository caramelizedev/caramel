require "../../../src/caramel/model"

class WrongOption < Caramel::Model
  table :wrong_options
  field id : Int64?, primary: true
  field name : String, default: "silently ignored"
end

WrongOption.new(name: "A")
