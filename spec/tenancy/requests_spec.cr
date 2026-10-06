require "./support/app"

private alias Tenancy = Caramel::Tenancy

# Acme with one book, and Globex with none.
private def acme_with_a_book : {TenancySpec::Account, TenancySpec::Book}
  acme = TenancySpec.account("acme")
  TenancySpec.account("globex")
  book = TenancySpec.book(acme, TenancySpec.author(acme), "Acme Atlas")
  {acme, book}
end

describe "A tenant route" do
  it "lists only its tenant's rows" do
    acme_with_a_book
    globex = TenancySpec::Account.query.where(slug: "globex").first!
    TenancySpec.book(globex, TenancySpec.author(globex), "Globex Guide")
    TenancySpec.get("/acme/books").body.should eq("Acme Atlas")
  end

  it "answers 404 for another tenant's record" do
    _, book = acme_with_a_book
    TenancySpec.get("/acme/books/#{book.id}").body.should eq("Acme Atlas")
    TenancySpec.get("/globex/books/#{book.id}").status.should eq(404)
  end

  it "answers 404 for an unknown tenant" do
    acme_with_a_book
    TenancySpec.get("/nobody/books").status.should eq(404)
  end

  it "writes path helpers under its tenant's prefix" do
    acme_with_a_book
    TenancySpec.get("/acme").body.should eq("acme /acme/books")
  end

  it "streams its body in its tenant" do
    acme_with_a_book
    TenancySpec.served("/acme/books-stream").should end_with("acme 1")
  end

  it "takes a method override within its tenant" do
    _, book = acme_with_a_book
    renamed = TenancySpec.post("/acme/books/#{book.id}", "_method=PATCH&title=Renamed")
    renamed.body.should eq("Renamed")
  end

  it "refuses a method override aimed at another tenant's record" do
    _, book = acme_with_a_book
    refused = TenancySpec.post("/globex/books/#{book.id}", "_method=PATCH&title=Taken")
    refused.status.should eq(404)
  end

  it "lists the methods its tenant routes take when the method is wrong" do
    acme_with_a_book
    wrong = TenancySpec.post("/acme/books", "title=Wrong")
    wrong.status.should eq(405)
    wrong.headers["Allow"].should eq("GET, HEAD")
  end
end

describe "A locale switch" do
  it "redirects a tenant page to its locale under the tenant's prefix" do
    acme_with_a_book
    switched = TenancySpec.get("/acme/books?locale=fr")
    switched.headers["Location"].should eq("/acme/fr/books")
  end

  it "redirects a tenant's home to its locale under the tenant's prefix" do
    acme_with_a_book
    TenancySpec.get("/acme?locale=fr").headers["Location"].should eq("/acme/fr")
  end

  it "serves a tenant page under a locale prefix" do
    acme_with_a_book
    TenancySpec.get("/acme/fr/books").body.should eq("Acme Atlas")
  end

  it "links a tenant page's language switcher within the tenant" do
    acme_with_a_book
    switcher = TenancySpec.get("/acme/fr/language").body
    switcher.should eq("/acme/fr/language /acme/language?locale=en")
  end

  it "links a central page's language switcher without a tenant" do
    acme_with_a_book
    TenancySpec.get("/fr/switcher").body.should eq("/fr/switcher /switcher?locale=en")
  end

  it "prefixes a root query path with the tenant alone" do
    acme, _ = acme_with_a_book
    prefixed = Tenancy.with(acme) { Caramel.tenant_path("/?locale=en") }
    prefixed.should eq("/acme?locale=en")
  end
end

describe "A central route" do
  it "stays central" do
    acme_with_a_book
    TenancySpec.get("/").body.should eq("tenant: none")
    TenancySpec.get("/health").body.should eq("ok")
  end

  it "sees no tenant on a fiber that just served one" do
    acme_with_a_book
    TenancySpec.get("/acme/books")
    TenancySpec.get("/").body.should eq("tenant: none")
  end

  it "sees no tenant when requested inside Caramel::Tenancy.with" do
    acme, _ = acme_with_a_book
    Tenancy.with(acme) { TenancySpec.get("/") }.body.should eq("tenant: none")
  end
end

describe "The routes listing" do
  it "shows tenant routes under /:tenant" do
    listing = TenancySpec.printed do
      Caramel::CommandLine.run(TenancySpec, ["routes"], Dir.current)
    end
    lines = listing.lines.map(&.split)
    lines.should contain(["GET", "/:tenant/books", "Books"])
    lines.should contain(["GET", "/:tenant", "Dashboard"])
    lines.should contain(["GET", "/health", "Health"])
  end
end

describe "SugarORM::Changeset#validate_tenant_slug" do
  it "refuses a central route's first segment" do
    changeset = TenancySpec::AccountChangeset.new(name: "Health", slug: "health")
    changeset.errors.should eq({"slug" => [SugarORM::Wording.taken]})
  end

  it "refuses a locale prefix" do
    changeset = TenancySpec::AccountChangeset.new(name: "French", slug: "fr")
    changeset.errors.should eq({"slug" => [SugarORM::Wording.taken]})
  end

  it "refuses a slug that is not a lowercase DNS label" do
    %w[Acme a_b -acme].each do |slug|
      changeset = TenancySpec::AccountChangeset.new(name: "Acme", slug: slug)
      changeset.errors.should eq({"slug" => [SugarORM::Wording.invalid_format]})
    end
  end

  it "accepts a lowercase DNS label" do
    TenancySpec::AccountChangeset.new(name: "Acme", slug: "acme-2").errors.should be_empty
  end
end

# Keeps every finished trace.
private class TenancyTraceSink < Caramel::Crema::Sink
  getter events = [] of Caramel::Crema::TraceEvent

  def name : String
    "tenancy-spec"
  end

  def finished(trace : Caramel::Crema::Trace) : Nil
    @events << trace.to_event(Caramel::Crema::Detail::Production)
  end
end

# The traces finished while the block ran.
private def traced(& : ->) : Array(Caramel::Crema::TraceEvent)
  sink = TenancyTraceSink.new
  Caramel::Crema.subscribe(sink)
  begin
    yield
  ensure
    Caramel::Crema.unsubscribe(sink)
  end
  sink.events
end

describe "Crema in a tenant" do
  it "names a tenant route under /:tenant" do
    acme_with_a_book
    request = traced { TenancySpec.get("/acme/books") }.first
    request.name.should eq("GET /:tenant/books")
    request.route.should eq("/:tenant/books")
  end

  it "runs a job enqueued in a tenant in the request's trace and in the tenant" do
    acme = TenancySpec.account("acme")
    events = traced do
      probe = HTTP::Request.new("GET", "/probe", HTTP::Headers.new)
      Caramel::Crema.request(probe) do
        Tenancy.with(acme) { TenancySpec::Record.enqueue }
        Caramel::Response.new
      end
      TenancySpec.drain
    end
    request = events.find! { |event| event.kind == "request" }
    job = events.find! { |event| event.kind == "job" }
    job.trace_id.should eq(request.trace_id)
    job.parent_id.should eq(request.span_id)
    TenancySpec::Run.query.order_by(:id).to_a.map(&.slug).should eq(["acme"])
  end
end
