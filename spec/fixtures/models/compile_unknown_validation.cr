require "../../../src/caramel/model"

class WrongValidation < Caramel::Model
  table :wrong_validations
  field id : Int64?, primary: true
  field name : String
  validates :name, presence: true, length: 5
end

WrongValidation.new(name: "A").valid?
