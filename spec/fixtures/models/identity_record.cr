require "../../../src/caramel/model"

class IdentityRecord < Caramel::Model
  table :typed_identities
  field id : Int64?, primary: true
end

class UntimedRecord < Caramel::Model
  table :typed_untimed
  field id : Int64?, primary: true
  field name : String
end
