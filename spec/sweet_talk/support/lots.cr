# Lots of units and the amount they carry, for SweetTalk's calculations (ADR 0062): a split
# whose rule holds, the same split with its shares rounded on their own, whose rule breaks,
# and a value of a lot with a never line on its result.
require "../../../src/caramel/sweet_talk/decimal"

module Lots
  include SweetTalk

  context Carrying, means: "the amount a lot of units carries, settled unit by unit" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"
    value Units, Int32, at_least: 0, at_most: 1_000, means: "a count of units"
    value Rate, Decimal(9, 4), at_least: "0", at_most: "1", means: "a share from 0 to 1"
    value Kind, String, one_of: %w[bought gifted], means: "how a lot came in"
    value Day, Date, means: "a calendar day"

    value Origin, means: "how and when a lot came in" do
      part kind : Kind
      part day : Day
    end

    aggregate Lot, means: "units bought together" do
      has total : Cents
    end

    calculation consume(total : Cents, settlements : Array(Units)), returns: Array(Cents),
      means: "the carrying amount each settlement consumes, the lot being all of them" do
      always "settling every unit consumes the whole carrying amount" do
        result.sum(0_i64, &.raw) == total.raw
      end
      lot = settlements.sum(0_i64, &.raw)
      raise SweetTalk::Refusal.new("A lot settles at least one unit.") if lot.zero?
      settled = 0_i64
      settlements.map do |units|
        before = total.raw * settled // lot
        settled += units.raw
        Cents.new(total.raw * settled // lot - before)
      end
    end

    calculation consume_carelessly(total : Cents, settlements : Array(Units)),
      returns: Array(Cents), means: "the same split, each share rounded down on its own" do
      always "settling every unit consumes the whole carrying amount" do
        result.sum(0_i64, &.raw) == total.raw
      end
      lot = settlements.sum(0_i64, &.raw)
      raise SweetTalk::Refusal.new("A lot settles at least one unit.") if lot.zero?
      settlements.map { |units| Cents.new(total.raw * units.raw // lot) }
    end

    calculation worth(held : Cents, origin : Origin, discount : Rate?), returns: Cents,
      means: "what a lot is worth: what it carries, less a discount when it was a gift" do
      never "a lot is worth more than it carries" do
        result > held
      end
      share = discount && origin.kind.gifted? ? discount.raw : BigDecimal.new(0)
      Cents.new((BigDecimal.new(held.raw) * (BigDecimal.new(1) - share)).to_i64)
    end

    service record_carelessly(total : Cents, settlements : Array(Units)),
      means: "records a lot, then splits it with the careless calculation" do
      Lot.create(total: total)
      consume_carelessly(total, settlements)
    end

    publishes Cents, Units, consume
  end
end
