require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Counter, means: "a counter where money changes hands" do
    value Kind, String, one_of: %w[trade cash fee], means: "what a transfer does"
    projection Totals, means: "totals of one kind" do
      key tag : String
      has payee : String?
      has kind : Kind = Kind.trade, parts: {trade: [payee]}
    end
  end
end

SweetTalk.boot
