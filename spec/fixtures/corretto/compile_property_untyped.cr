require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total, parts : Int32)
    total // parts
  end
end

Corretto.property(Billing.share)
