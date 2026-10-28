require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering], means: "the money the shop agrees on" do
    aggregate Rate, means: "what a dollar costs today" do
      has pence : Int64 = 0_i64

      to refresh do
        @pence = Caramel::Outbound.get("https://rates.example/usd").body.to_i64
      end
    end
  end
end

SweetTalk.boot
