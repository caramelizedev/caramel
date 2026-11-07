# A till that sells tins of tea and writes receipts, to preview a change before it commits
# and to commit it against that preview (ADR 0060).

# A system outside the program, reached from a module the context does not hold, so the
# context's check on the code as written cannot see it; a preview refuses it at run time.
module PreviewGateway
  def self.ask : Nil
    Caramel::Outbound.get("https://gateway.example/v1/ping")
  end
end

module PreviewShop
  include SweetTalk
  ids Int64

  context Till, event_log: true, means: "selling tins over the counter" do
    value Tins, Int32, means: "a count of tins"
    value Cents, Int64, means: "an amount of money"
    value Ticket, String, means: "the key a till sends with one sale"

    aggregate Tea, means: "one tea on the shelf" do
      has name : String
      has price : Cents
      has stock : Tins
      has sold_at : Time?
      event Sold, tins : Tins, price : Cents, means: "tins left the shelf at a price"
      event RanOut, means: "the last tin was sold"
      event Restocked, tins : Tins, means: "fresh tins reached the shelf"

      to sell(tins : Tins) do
        refuse "Only #{stock} tins of #{name} left." if tins > stock
        @stock -= tins
        @sold_at = Time.utc
        emit Sold, tins: tins, price: price
        emit RanOut if stock == Tins.zero
      end

      to restock(tins : Tins) do
        @stock += tins
        emit Restocked, tins: tins
      end

      to reprice(price : Cents) do
        @price = price
      end

      to retire do
        remove
      end
    end

    aggregate Receipt, means: "what one sale took" do
      has tea : Tea
      has total : Cents
      moves written >> voided
      event Written, total : Cents, means: "a receipt was written"

      factory write(tea : Tea, total : Cents) do
        emit Written, total: total
      end

      to void do
        voided!
      end
    end

    projection Takings, means: "tins sold of one tea" do
      key tea : Tea
      has tins : Int32 = 0

      whenever Tea::Sold do |sold|
        row = Takings[sold.tea_id]
        row.tins += sold.tins.to_i
      end
    end

    unit sell(tea : Tea::Id, tins : Tins), changes: [Tea, Receipt], locks: [tea],
      returns: Receipt::Id, means: "sells tins of one tea and writes its receipt" do
      found = Tea.find(tea)
      found.sell tins
      Receipt.write(found, found.price * tins.to_i).id
    end

    unit sell_once(ticket : Ticket, tea : Tea::Id, tins : Tins), changes: [Tea, Receipt],
      locks: [tea], returns: Receipt::Id, once_by: ticket,
      means: "sells tins of one tea once for each ticket" do
      found = Tea.find(tea)
      found.sell tins
      Receipt.write(found, found.price * tins.to_i).id
    end

    unit discount(tea : Tea::Id, price : Cents), changes: [Tea], locks: [tea],
      means: "lowers the price of one tea" do
      found = Tea.find(tea)
      was = found.price
      found.reprice price
      warn "The new price is less than half the old one." { price.raw * 2 < was.raw }
    end

    unit sell_and_ask(tea : Tea::Id, tins : Tins), changes: [Tea, Receipt], locks: [tea],
      means: "sells tins and asks the gateway, which a unit must not do" do
      found = Tea.find(tea)
      found.sell tins
      PreviewGateway.ask
    end
  end
end
