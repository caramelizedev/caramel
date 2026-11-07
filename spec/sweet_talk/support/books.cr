# Books kept in several currencies, for SweetTalk's money module (ADR 0063): a kernel of
# currencies and a dated rate shared by two contexts; amounts whose currency is data,
# stored with their currency column, optional or not, in an aggregate, an entity and a
# projection, carried by an event and asked for by a finder and a specification; an amount
# whose currency is a type; rates read exactly and stored part by part; allocations with
# each remainder; and a split with an off-by-one seeded, for the property case.
require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Books
  include SweetTalk
  ids Int64

  kernel Cash, shared_by: [Payments, Rates], means: "how the books count money" do
    currencies %w[USD EUR UZS JPY BHD TRY XAU], exponent: {XAU: 4},
      means: "a currency the books hold"
    quote Rate, rounding: :half_up, means: "one dated rate from a named source"
  end

  context Payments, shares: Cash, means: "the journal of what was paid and received" do
    value Weight, Decimal(9, 6), at_least: "0", at_most: "100", means: "an owner's percent"

    allocation split, of: Cash::Amount, by: Weight, remainder: :largest_fraction, ties: :key,
      means: "a month's distributable profit, owner by owner"
    allocation sweep, of: Cash::Amount, by: Weight, remainder: :to,
      means: "a payout whose rounding goes to the managing owner"
    allocation front, of: Cash::Amount, by: Weight, remainder: :first,
      means: "a payout whose rounding goes to the first owner"
    allocation back, of: Cash::Minor(Cash::Currency::JPY), by: Int32, remainder: :last,
      means: "yen shared by whole shares, the rounding to the last owner" do
      always "no part is below zero" { result.values.none?(&.negative?) || total.negative? }
    end

    # The largest-fraction split with Astrona's off-by-one seeded: one unit too few goes out,
    # which the rule every allocation declares catches.
    calculation short(total : Cash::Amount, weights : Hash(Int64, Weight)),
      returns: Hash(Int64, Cash::Amount), means: "split, one unit short when units are left" do
      always "the parts add up to the total, in its currency" do
        ::SweetTalk::Money.summed?(result, total)
      end
      units = ::SweetTalk::Money.units(total)
      exact = ::SweetTalk::Money.shares(units, weights)
      parts = exact.transform_values { |share| (share.numerator // share.denominator).to_i64 }
      left = units.abs - parts.values.sum(0_i64)
      keys = exact.keys.sort_by! { |key| {BigRational.new(parts[key]) - exact[key], key} }
      keys.first({left - 1, 0_i64}.max).each { |key| parts[key] += 1 }
      sign = units < 0 ? -1 : 1
      parts.to_h do |key, part|
        {key, ::SweetTalk::Money.rebuild(total, part * sign).as(Cash::Amount)}
      end
    end

    aggregate Entry, means: "one payment, in the currency it was made in" do
      has original : Cash::Amount
      has reported : Cash::Amount?
      has fee : Cash::Minor(Cash::Currency::USD)?
      has rate : Cash::Rate?
      has lines : Array(Line)

      entity Line, means: "a part of an entry, in a currency of its own" do
        has share : Cash::Amount
      end

      event Reported, carries: [original, reported], means: "an entry was converted"

      finds of_amount(amount : Cash::Amount), where: {original: amount}
      finds unreported, where: {reported: nil}

      to report(rate : Cash::Rate) do
        @reported = original.convert(rate)
        @rate = rate
        emit Reported
      end

      to charge(fee : Cash::Minor(Cash::Currency::USD)?) do
        @fee = fee
      end

      to split(shares : Array(Cash::Amount)) do
        @lines = shares.map { |share| Line.new(share: share) }
      end
    end

    projection Totals, means: "the last converted amount of each entry" do
      key entry : Entry
      has reported : Cash::Amount?
      has conversions : Int32 = 0

      whenever Entry::Reported do |reported|
        row = Totals[reported.entry_id]
        row.reported = reported.reported
        row.conversions += 1
      end
    end

    specification Unreported, on: Entry, where: {reported: nil},
      means: "an entry not yet converted"
  end

  context Rates, shares: Cash, means: "the rates the books convert with" do
    aggregate Quote, means: "a rate as its source published it" do
      has rate : Cash::Rate
    end
  end
end
