require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total : Int64, parts : Int32) : Int64
    total // parts
  end
end

Corretto.property(Billing.share(100_i64, 3))
