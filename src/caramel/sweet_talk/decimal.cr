# Decimal values: `value Rate, Decimal(20, 8), at_least: "0", means: "…"` in a context.
# Opt-in, because a `BigDecimal` links GMP: a program that declares no decimal value
# requires only `caramel/sweet_talk`, and one that does requires this file as well.
require "big"
require "../../sugar_orm/decimal"
require "../sweet_talk"

module SweetTalk
  # The words every decimal value shares.
  module Decimal
    # Reads *text*, digits with at most one point, as a decimal, or refuses in *name*'s
    # words: `1e3`, `1,5` and ` 2` are not decimals written that way.
    def self.parse(name : String, text : String) : BigDecimal
      raise Refusal.new(refusal(name)) unless text.matches?(::SugarORM::Decimal::TEXT)
      BigDecimal.new(text)
    end

    def self.refusal(name : String) : String
      "#{name} must be a decimal written with digits and a point, as in 12.50"
    end
  end
end
