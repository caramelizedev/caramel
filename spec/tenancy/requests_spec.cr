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
