# A treasury that lends at a rate, for SweetTalk's decimal and JSON values (ADR 0047): a
# decimal value with bounds kept in a numeric column and a CHECK, ranged, sorted and
# counted; a JSON value over a JSON::Serializable type and one over any document, kept in
# jsonb columns, optional in an aggregate and in a projection; and an event that carries
# both.
require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/decimal"

module Treasury
  include SweetTalk

  # The figures a rate was set from.
  struct Snapshot
    include JSON::Serializable

    getter source : String
    getter base_points : Int32

    def initialize(@source : String, @base_points : Int32)
    end
  end

  context Credit, means: "money lent at a yearly rate, with the figures behind each rate" do
    value Rate, Decimal(20, 8), at_least: "0", at_most: "1", means: "a yearly rate, 0 to 1"
    value Spread, Decimal(6, 4), at_least: "-0.5", means: "a margin over the base rate"
    value Share, Decimal(5, 2), at_most: "1", otherwise: "A share is at most the whole.",
      means: "a part of one"
    value Evidence, Json(Snapshot), means: "the figures a rate was set from"
    value Note, Json, means: "any document a lender attaches to a loan"

    aggregate Loan, means: "money lent to one borrower at one rate" do
      has borrower : String
      has rate : Rate
      has spread : Spread?
      has evidence : Evidence?
      has note : Note?

      event Repriced, carries: [rate, evidence], means: "a loan's rate was set from figures"

      finds priced_between(low : Rate, high : Rate), where: {rate: low..high}
      finds priced_from(low : Rate), where: {rate: low..}
      finds priced_at(rate : Rate), where: {rate: rate}
      finds cheapest_first, order: {rate: :asc}
      finds evidenced_by(evidence : Evidence), where: {evidence: evidence}
      finds unevidenced, where: {evidence: nil}
      counts priced_from_count(low : Rate), where: {rate: low..}

      to reprice(rate : Rate, evidence : Evidence) do
        @rate = rate
        @evidence = evidence
        emit Repriced
      end

      to widen(spread : Spread?) do
        @spread = spread
      end

      to annotate(note : Note?) do
        @note = note
      end
    end

    projection Pricing, means: "the last rate and figures each loan was priced with" do
      key loan : Loan
      has rate : Rate?
      has evidence : Evidence?
      has repricings : Int32 = 0

      whenever Loan::Repriced do |repriced|
        row = Pricing[repriced.loan_id]
        row.rate = repriced.rate
        row.evidence = repriced.evidence
        row.repricings += 1
      end
    end

    @@repricings = [] of String

    # What each Repriced handler saw, as text, in the order they ran.
    def self.repricings : Array(String)
      @@repricings
    end

    whenever Loan::Repriced do |repriced|
      repricings << "#{repriced.rate}|#{repriced.evidence.try(&.raw.source)}"
    end

    specification Cheap, on: Loan, where: {rate: Rate.new("0")..Rate.new("0.05")},
      means: "a loan priced at five percent or less"
    specification Free, on: Loan, where: {rate: Rate.new("0")},
      means: "a loan priced at nothing"
    specification Unevidenced, on: Loan, where: {evidence: nil},
      means: "a loan priced without figures"
  end
end
