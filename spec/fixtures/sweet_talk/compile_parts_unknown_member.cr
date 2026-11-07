require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Counter, means: "a counter where money changes hands" do
    value Kind, String, one_of: %w[trade cash fee], means: "what a transfer does"
    aggregate Transfer, means: "one movement of money" do
      has payee : String?
      has kind : Kind, parts: {gift: [payee]}
    end
  end
end

SweetTalk.boot
