# SweetTalk's preview and commit (ADR 0060): a preview runs the body and rolls it back,
# leaving no receipt, job or log row; two previews of the same change agree, though the
# clock and the id sequence moved; a commit against that fingerprint keeps the change, and
# one against a world that moved raises Stale and writes nothing.
require "./support/app"
require "./support/preview_web"

module PreviewSpec
  CSRF        = Caramel::CSRF.new("p" * 64, "https://till.caramel")
  APPLICATION = Caramel::Application.new(PreviewWeb::AppRouter.new, CSRF)

  def self.tea(stock : Int32) : PreviewShop::Till::Tea
    PreviewShop::Till::Tea.create(name: "Sencha", price: PreviewShop::Till::Cents.new(300),
      stock: PreviewShop::Till::Tins.new(stock))
  end

  def self.sell(tea : PreviewShop::Till::Tea, tins : Int32 = 2) : PreviewShop::Till::Receipt::Id
    PreviewShop::Till.sell(tea.id, PreviewShop::Till::Tins.new(tins))
  end

  def self.stock(tea : PreviewShop::Till::Tea) : Int32
    PreviewShop::Till::Tea.find(tea.id).stock.raw
  end

  # Receipts, jobs and logged events, as stored.
  def self.counts : {Int64, Int64, Int64}
    {SweetTalkSpec.count("till_receipts"), SweetTalkSpec.count("caramel_jobs"),
     SweetTalkSpec.count("till_events")}
  end

  def self.request(method : String, path : String, body : String? = nil,
                   accept : String = "text/html") : Caramel::Response
    headers = HTTP::Headers{"Host" => "till.caramel", "Accept" => accept,
                            "Content-Type" => "application/x-www-form-urlencoded"}
    APPLICATION.handle(HTTP::Request.new(method, path, headers, body))
  end

  def self.hidden(page : Caramel::Response) : String
    page.body[/name="expected" value="(\w+)"/, 1]
  end
end

describe "SweetTalk's preview and commit" do
  it "previews the events a sale would emit and keeps nothing" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      before = PreviewSpec.counts
      preview = SweetTalk.preview { PreviewSpec.sell(tea) }
      preview.events.map { |event| {event.name, event.subject, event.fields.to_json} }
        .should eq([{"PreviewShop::Till::Tea::Sold", "Tea #{tea.id}", %({"tins":2,"price":300})},
                    {"PreviewShop::Till::Receipt::Written", "new Receipt #1", %({"total":600})}])
      preview.refusal.should be_nil
      PreviewSpec.counts.should eq(before)
      PreviewSpec.stock(tea).should eq(5)
    end
  end

  it "gives two previews of one change one fingerprint, though the clock and the ids moved" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      first = SweetTalk.preview { PreviewSpec.sell(tea) }
      second = SweetTalk.preview { PreviewSpec.sell(tea) }
      second.fingerprint.should eq(first.fingerprint)
      second.changes.map(&.subject).should eq(["Tea #{tea.id}", "new Receipt #1"])
      second.changes[0].after["sold_at"].should eq("time")
      second.changes[1].after["tea"].should eq(tea.id.raw)
    end
  end

  it "commits against the preview's fingerprint" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      receipts, jobs, logged = PreviewSpec.counts
      preview = SweetTalk.preview { PreviewSpec.sell(tea) }
      receipt = SweetTalk.commit(preview.fingerprint) { PreviewSpec.sell(tea) }
      PreviewShop::Till::Receipt.find(receipt).total.raw.should eq(600)
      PreviewSpec.stock(tea).should eq(3)
      PreviewSpec.counts.should eq({receipts + 1, jobs + 1, logged + 2})
    end
  end

  it "raises Stale when a silent command changed the row, and writes nothing" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      preview = SweetTalk.preview { PreviewSpec.sell(tea) }
      PreviewShop::Till::Tea.find(tea.id).reprice(PreviewShop::Till::Cents.new(350))
      before = PreviewSpec.counts
      stale = expect_raises(SweetTalk::Stale, "This changed since it was previewed.") do
        SweetTalk.commit(preview.fingerprint) { PreviewSpec.sell(tea) }
      end
      stale.preview.events[0].fields["price"].should eq(350)
      PreviewSpec.counts.should eq(before)
      PreviewSpec.stock(tea).should eq(5)
    end
  end

  it "tells two previews with the same events apart by the rows they leave" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      first = SweetTalk.preview { PreviewSpec.sell(tea) }
      PreviewShop::Till::Tea.find(tea.id).restock(PreviewShop::Till::Tins.new(10))
      second = SweetTalk.preview { PreviewSpec.sell(tea) }
      second.events.should eq(first.events)
      second.fingerprint.should_not eq(first.fingerprint)
      second.changes[0].after["stock"].should eq(13)
    end
  end

  it "raises Stale with the fresh preview when the change would emit another event" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(4)
      preview = SweetTalk.preview { PreviewSpec.sell(tea) }
      PreviewSpec.sell(tea)
      stale = expect_raises(SweetTalk::Stale) do
        SweetTalk.commit(preview.fingerprint) { PreviewSpec.sell(tea) }
      end
      stale.preview.events.map(&.name).should eq(%w[PreviewShop::Till::Tea::Sold
        PreviewShop::Till::Tea::RanOut PreviewShop::Till::Receipt::Written])
      PreviewSpec.stock(tea).should eq(2)
    end
  end

  it "previews a refusal as its sentence alone" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(1)
      preview = SweetTalk.preview { PreviewSpec.sell(tea) }
      preview.refusal.should eq("Only 1 tins of Sencha left.")
      preview.events.should be_empty
      preview.changes.should be_empty
    end
  end

  it "reloads what a dry run changed on an instance it was given" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      preview = SweetTalk.preview { tea.restock(PreviewShop::Till::Tins.new(4)) }
      preview.changes[0].after["stock"].should eq(9)
      tea.stock.raw.should eq(5)
    end
  end

  it "names an aggregate create made, with its Created event, by its placeholder" do
    SweetTalkSpec.rolled_back do
      preview = SweetTalk.preview { PreviewSpec.tea(7) }
      preview.events.map { |event| {event.name, event.subject} }
        .should eq([{"PreviewShop::Till::Tea::Created", "new Tea #1"}])
      preview.changes[0].made?.should be_true
      PreviewShop::Till::Tea.all.size.should eq(0)
    end
  end

  it "keeps no operation claim from a preview of a unit that runs once" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      ticket = PreviewShop::Till::Ticket.new("till-1")
      tins = PreviewShop::Till::Tins.new(2)
      preview = SweetTalk.preview { PreviewShop::Till.sell_once(ticket, tea.id, tins) }
      SweetTalkSpec.count("till_operations").should eq(0)
      SweetTalk.commit(preview.fingerprint) { PreviewShop::Till.sell_once(ticket, tea.id, tins) }
      SweetTalkSpec.count("till_operations").should eq(1)
      PreviewSpec.stock(tea).should eq(3)
    end
  end

  it "summarises removals and final moves first, then each event and silent change" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      receipt = PreviewShop::Till::Receipt.find(PreviewSpec.sell(tea))
      other = PreviewSpec.tea(3)
      preview = SweetTalk.preview do
        other.reprice(PreviewShop::Till::Cents.new(10))
        tea.restock(PreviewShop::Till::Tins.new(1))
        receipt.void
        other.retire
      end
      preview.summary.map { |group| {group.aggregate, group.what, group.final} }
        .should eq([{"Tea", "removed", true}, {"Receipt", "moved to voided", true},
                    {"Tea", "Restocked", false}])
      JSON.parse(preview.to_json)["summary"].size.should eq(3)
    end
  end

  it "refuses a preview inside a preview" do
    SweetTalkSpec.rolled_back do
      expect_raises(SweetTalk::Boundary) do
        SweetTalk.preview { SweetTalk.preview { nil } }
      end
    end
  end

  it "binds a fingerprint as a contract field and refuses other text" do
    hex = "a" * 64
    SweetTalk::Fingerprint.from_field(hex) { |message| fail message }.should eq(
      SweetTalk::Fingerprint.new(hex))
    refused = nil
    SweetTalk::Fingerprint.from_field("abc") { |message| refused = message }.should be_nil
    refused.should eq("is not a preview's fingerprint")
  end

  it "commits a form's sale, and answers a stale one 422 with the fresh fingerprint" do
    SweetTalkSpec.rolled_back do
      tea = PreviewSpec.tea(5)
      form = PreviewSpec.request("GET", "/till/#{tea.id}/sell?tins=2")
      form.status.should eq(200)
      form.body.should contain("<p>Tea Sold; Receipt Written</p>")
      expected = PreviewSpec.hidden(form)
      PreviewShop::Till::Tea.find(tea.id).reprice(PreviewShop::Till::Cents.new(350))

      stale = PreviewSpec.request("POST", "/till/#{tea.id}/sell", "tins=2&expected=#{expected}")
      stale.status.should eq(422)
      fresh = PreviewSpec.hidden(stale)
      fresh.should_not eq(expected)
      PreviewSpec.stock(tea).should eq(5)

      json = PreviewSpec.request("POST", "/till/#{tea.id}/sell", "tins=2&expected=#{expected}",
        "application/json")
      json.status.should eq(422)
      answer = JSON.parse(json.body)
      answer["errors"]["_base"].should eq(["This changed since it was previewed. Review it again."])
      answer["preview"]["fingerprint"].should eq(fresh)

      done = PreviewSpec.request("POST", "/till/#{tea.id}/sell", "tins=2&expected=#{fresh}")
      done.status.should eq(200)
      PreviewSpec.stock(tea).should eq(3)
    end
  end
end
