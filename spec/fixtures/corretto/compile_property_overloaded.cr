require "../../../src/caramel/corretto/property"

module Billing
  def self.share(total : Int64, parts : Int32) : Int64
    total // parts
  end

  def self.share(total : Int32, parts : Int32) : Int32
    total // parts
  end
end

Corretto.property(Billing.share)
