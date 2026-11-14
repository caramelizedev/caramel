require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total : Int64, *parts : Int32) : Int64
    total // parts.sum
  end
end

Corretto.property(Billing.share)
