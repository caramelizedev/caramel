require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total : T, parts : Int32) : T forall T
    total // parts
  end
end

Corretto.property(Billing.share)
