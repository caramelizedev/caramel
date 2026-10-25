# SweetTalk at the web boundary (ADR 0034): a refusal that an action does not rescue
# answers 422 in the contract-failure shapes, a missing aggregate 404, and a second
# aggregate in one command stays a 500.
require "./support/app"
require "./support/web"

module WebSpec
  CSRF        = Caramel::CSRF.new("s" * 64, "https://teashop.caramel")
  APPLICATION = Caramel::Application.new(TeaShopWeb::AppRouter.new, CSRF)
  REPORTS     = [] of Caramel::Crema::ErrorReport
  Caramel::Crema.on_error { |report| REPORTS << report }

  def self.get(path : String, headers = HTTP::Headers.new) : Caramel::Response
    headers["Host"] = "teashop.caramel"
    APPLICATION.handle(HTTP::Request.new("GET", path, headers))
  end

  def self.post(path : String, body : String, accept = "*/*") : Caramel::Response
    headers = HTTP::Headers{"Host" => "teashop.caramel", "Accept" => accept,
                            "Content-Type" => "application/x-www-form-urlencoded"}
    APPLICATION.handle(HTTP::Request.new("POST", path, headers, body))
  end

  def self.post_json(path : String, body : String) : Caramel::Response
    headers = HTTP::Headers{"Host" => "teashop.caramel", "Accept" => "application/json",
                            "Content-Type" => "application/json"}
    APPLICATION.handle(HTTP::Request.new("POST", path, headers, body))
  end

  def self.accepting(type : String) : HTTP::Headers
    HTTP::Headers{"Accept" => type}
  end

  def self.tea : TeaShop::Catalogue::Tea
    TeaShop::Catalogue::Tea.create(name: "Sencha", price: TeaShop::Catalogue::Cents.new(100),
      stock: TeaShop::Catalogue::Tins.new(3))
  end

  def self.box(label : String) : Rules::Shelf::Box
    Rules::Shelf::Box.create(label: label, count: Rules::Shelf::Count.new(0))
  end
end

describe "SweetTalk at the web boundary" do
  it "answers a refusal with 422 under _base, as JSON, a page or MRDP text" do
    SweetTalkSpec.rolled_back do
      tea = WebSpec.tea.id.raw
      json = WebSpec.get("/teas/#{tea}/hold?tins=5", WebSpec.accepting("application/json"))
      json.status.should eq(422)
      json.headers["Content-Type"].should eq("application/json")
      json.body.should eq(%({"errors":{"_base":["Only 3 tins of Sencha free."]}}))

      page = WebSpec.get("/teas/#{tea}/hold?tins=5", WebSpec.accepting("text/html"))
      page.status.should eq(422)
      page.headers["Content-Type"].should eq("text/html; charset=utf-8")
      page.body.should contain("<title>Check your request</title>")
      page.body.should contain("<li><code>_base</code>: Only 3 tins of Sencha free.</li>")

      text = WebSpec.get("/teas/#{tea}/hold?tins=5", WebSpec.accepting("*/*"))
      text.status.should eq(422)
      text.headers["Content-Type"].should eq("text/plain; charset=utf-8")
      text.body.should eq("ERR INVALID:422 at GET /teas/#{tea}/hold\n" \
                          "FIELD _base: Only 3 tins of Sencha free.\n")
    end
  end

  it "answers an htmx request with the Check your request fragment" do
    SweetTalkSpec.rolled_back do
      headers = HTTP::Headers{"HX-Request" => "true", "HX-Request-Type" => "partial"}
      response = WebSpec.get("/teas/#{WebSpec.tea.id.raw}/hold?tins=5", headers)
      response.status.should eq(422)
      response.body.should start_with(
        %(<title>Check your request</title><section class="contract-errors" role="alert">))
    end
  end

  it "re-renders a form that overrides contract_failure_page with the refusal" do
    SweetTalkSpec.rolled_back do
      response = WebSpec.get("/teas/#{WebSpec.tea.id.raw}/form?tins=5",
        WebSpec.accepting("text/html"))
      response.status.should eq(422)
      response.body.should contain("<title>Hold tins</title>")
      response.body.should contain(%(<form>["Only 3 tins of Sencha free."]</form>))
    end
  end

  it "answers a refusal built from a value too" do
    SweetTalkSpec.rolled_back do
      response = WebSpec.get("/teas/#{WebSpec.tea.id.raw}/hold?tins=-1", WebSpec.accepting("*/*"))
      response.status.should eq(422)
      response.body.should contain("FIELD _base: Tins must be at least 0")
    end
  end

  it "answers 404 for an aggregate that find cannot find" do
    SweetTalkSpec.rolled_back do
      response = WebSpec.get("/teas/#{Int64::MAX}/hold?tins=1", WebSpec.accepting("*/*"))
      response.status.should eq(404)
      response.body.should eq("Not found")
    end
  end

  it "reports neither to Crema, and rolls the refused command back" do
    SweetTalkSpec.rolled_back do
      WebSpec::REPORTS.clear
      tea = WebSpec.tea
      WebSpec.get("/teas/#{tea.id.raw}/hold?tins=5", WebSpec.accepting("*/*")).status.should eq(422)
      WebSpec.get("/teas/#{Int64::MAX}/hold?tins=1").status.should eq(404)
      WebSpec::REPORTS.size.should eq(0)
      TeaShop::Catalogue::Tea.find(tea.id).held.raw.should eq(0)
      TeaShop::Catalogue::Tea.find(tea.id).stock.raw.should eq(3)
    end
  end

  it "passes a refusal that handle rescues through unchanged" do
    SweetTalkSpec.rolled_back do
      response = WebSpec.get("/teas/#{WebSpec.tea.id.raw}/claim?tins=5")
      response.status.should eq(409)
      response.body.should eq("Only 3 tins of Sencha free.")
    end
  end

  it "keeps a second aggregate in one command a 500" do
    SweetTalkSpec.rolled_back do
      WebSpec::REPORTS.clear
      first, second = WebSpec.box("first"), WebSpec.box("second")
      response = WebSpec.get("/boxes/#{first.id.raw}/fill?from=#{second.id.raw}",
        WebSpec.accepting("application/json"))
      response.status.should eq(500)
      response.body.should start_with("Something went wrong. Reference: ")
      WebSpec::REPORTS.size.should eq(1)
      WebSpec::REPORTS.first.handled?.should be_false
      WebSpec::REPORTS.first.error_class.should eq("SweetTalk::Boundary")
    end
  end

  it "answers a value's refusal under its field" do
    response = WebSpec.post("/orders/7/lines", "quantity=11", "application/json")
    response.status.should eq(422)
    response.body.should eq(%({"errors":{"quantity":["Quantity must be between 1 and 10"]}}))
  end

  it "binds an aggregate's id from the route and 404s one that is not an Int64" do
    response = WebSpec.post("/orders/7/lines", "quantity=3")
    response.status.should eq(200)
    response.body.should eq("order=7 quantity=3")
    WebSpec.post("/orders/abc/lines", "quantity=3").status.should eq(404)
  end

  it "binds a nilable string value and an array of values" do
    email = WebSpec.post("/orders/7/lines", "quantity=2&receipt_to=ada")
    email.status.should eq(422)
    email.body.should contain("FIELD receipt_to: Email must match /\\A[^@\\s]+@[^@\\s]+\\z/\n")
    tags = WebSpec.post("/orders/7/lines", "quantity=2&tags=1&tags=11&tags=1")
    tags.status.should eq(422)
    tags.body.should contain("FIELD tags[1]: Quantity must be between 1 and 10\n")
    tags.body.should contain("FIELD tags[2]: repeats an earlier item\n")
  end

  it "lists value fields with both types" do
    route = TeaShopWeb::AppRouter.routes.find! { |entry| entry.path == "/orders/:order/lines" }
    route.contract.should eq("order:Order::Id(Int64) quantity:Ordering::Quantity(Int32) " \
                             "receipt_to:Ordering::Email(String)? " \
                             "tags:Array(Ordering::Quantity(Int32))(max=3)")
  end

  it "binds a calendar day from YYYY-MM-DD, and answers days as JSON text" do
    form = "lent_on=2026-03-01&back_by=2026-03-22&holidays=2026-03-05&holidays=2026-03-06"
    response = WebSpec.post("/loans/lend", form, "application/json")
    response.status.should eq(200)
    response.body.should eq(<<-JSON.gsub(/\s+/, ""))
      {"lent_on":"2026-03-01","back_by":"2026-03-22",
       "holidays":["2026-03-05","2026-03-06"],"days":21}
      JSON
    WebSpec.post("/loans/lend", "lent_on=2028-02-29", "application/json").body
      .should eq(%({"lent_on":"2028-02-29","back_by":null,"holidays":[],"days":null}))
  end

  it "binds a calendar day from a JSON body too" do
    body = %({"lent_on":"2026-03-01","back_by":"2026-03-08","holidays":["2026-03-02"]})
    response = WebSpec.post_json("/loans/lend", body)
    response.status.should eq(200)
    response.body.should contain(%("days":7))
    WebSpec.post_json("/loans/lend", %({"lent_on":20260301})).status.should eq(422)
  end

  it "answers the refusal of a day, as the calendar words it, under its field" do
    refusal = "Day must be a calendar day written YYYY-MM-DD, as in 2026-02-28"
    form = "lent_on=2026-02-30&back_by=tomorrow"
    response = WebSpec.post("/loans/lend", form, "application/json")
    response.status.should eq(422)
    response.body.should eq(%({"errors":{"lent_on":["#{refusal}"],"back_by":["#{refusal}"]}}))
    list = "lent_on=2026-03-01&holidays=2026-03-05&holidays=2026-04-31"
    WebSpec.post("/loans/lend", list).body.should contain("FIELD holidays[1]: #{refusal}\n")
  end

  it "lists a day field by its type and its wire type" do
    route = TeaShopWeb::AppRouter.routes.find! { |entry| entry.path == "/loans/lend" }
    route.contract.should eq("lent_on:Lending::Day(String) back_by:Lending::Day(String)? " \
                             "holidays:Array(Lending::Day(String))(max=3)")
  end
end
