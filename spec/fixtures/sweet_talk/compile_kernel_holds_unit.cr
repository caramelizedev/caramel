require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering], means: "the money the shop agrees on" do
    aggregate Voucher, means: "money set aside under a code" do
      has code : String
    end

    unit merge(from : Voucher::Id, to : Voucher::Id), changes: [Voucher], locks: [from, to],
      means: "moves one voucher's money into another" do
      Voucher.find(from)
    end
  end
end

SweetTalk.boot
