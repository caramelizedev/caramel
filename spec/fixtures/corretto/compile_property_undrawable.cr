require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total : Float64, parts : Array(Int32?)) : Float64
    total / parts.size
  end
end

Corretto.property(Billing.share)
