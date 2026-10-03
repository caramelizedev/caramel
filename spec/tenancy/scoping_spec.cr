require "./support/app"

private alias Tenancy = Caramel::Tenancy
private alias Book = TenancySpec::Book
private alias Author = TenancySpec::Author

# Acme and Globex, with one book each.
private def two_tenants : {TenancySpec::Account, TenancySpec::Account}
  acme = TenancySpec.account("acme")
  globex = TenancySpec.account("globex")
  TenancySpec.book(acme, TenancySpec.author(acme), "Acme Atlas", "111")
  TenancySpec.book(globex, TenancySpec.author(globex), "Globex Guide", "222")
  {acme, globex}
end

# A record of *account*'s, loaded outside every tenant.
private def foreign_book(account : TenancySpec::Account) : Book
  Tenancy.without { Book.query.where(account_id: account.id).first! }
end

describe "A tenanted schema" do
  it "queries only the bound tenant's rows" do
    acme, _ = two_tenants
    Tenancy.with(acme) { Book.query.to_a.map(&.title) }.should eq(["Acme Atlas"])
  end

  it "counts and finds only the bound tenant's rows" do
    acme, globex = two_tenants
    other = foreign_book(globex)
    Tenancy.with(acme) do
      Book.query.count.should eq(1)
      Book.query.where(isbn: "222").exists?.should be_false
      Book.query.find(other.id).should be_nil
    end
  end

  it "keeps the scope through chained conditions" do
    acme, _ = two_tenants
    titles = Tenancy.with(acme) { Book.query.where("title <> ?", "").limit(5).to_a }
    titles.map(&.title).should eq(["Acme Atlas"])
  end

  it "deletes only the bound tenant's rows" do
    acme, _ = two_tenants
    Tenancy.with(acme) { Book.query.delete_all }.should eq(1)
    Tenancy.without { Book.query.to_a.map(&.title) }.should eq(["Globex Guide"])
  end

  it "preloads an association within the bound tenant" do
    acme, _ = two_tenants
    Tenancy.with(acme) do
      book = Book.query.preload(:author).first!
      book.author.account_id.should eq(acme.id)
      authors = Author.query.preload(:books).to_a
      authors.flat_map(&.books.map(&.title)).should eq(["Acme Atlas"])
    end
  end

  it "preloads the tenant itself" do
    acme, _ = two_tenants
    book = Tenancy.with(acme) { Book.query.preload(:account).first! }
    book.account.slug.should eq("acme")
  end

  it "stamps a new row with the bound tenant" do
    acme, _ = two_tenants
    author = Tenancy.with(acme) { Author.query.first! }
    TenancySpec.book(acme, author, "Second Atlas").account_id.should eq(acme.id)
  end

  it "refuses to update another tenant's record" do
    acme, globex = two_tenants
    other = foreign_book(globex)
    changeset = Tenancy.with(acme) { other.update(title: "Taken") }
    changeset.saved?.should be_false
    changeset.errors.should eq({"_base" => [SugarORM::Wording.record_gone]})
  end

  it "refuses to delete another tenant's record" do
    acme, globex = two_tenants
    other = foreign_book(globex)
    Tenancy.with(acme) { other.delete }.should be_false
    Tenancy.without { Book.query.count }.should eq(2)
  end

  it "raises outside every tenant" do
    two_tenants
    expect_raises(SugarORM::Tenancy::Missing,
      "TenancySpec::Book is tenanted, but no tenant is bound") do
      Book.query.to_a
    end
  end

  it "reaches every tenant's rows inside without" do
    two_tenants
    Tenancy.without { Book.query.count }.should eq(2)
  end

  it "refuses to create a row inside without" do
    two_tenants
    expect_raises(SugarORM::Tenancy::Missing, "A new TenancySpec::Author row needs a tenant") do
      Tenancy.without { Author.create(name: "Nobody") }
    end
  end
end

describe "A unique index of a tenanted schema" do
  it "allows the same value in two tenants" do
    acme, globex = two_tenants
    shared = TenancySpec.book(globex, TenancySpec.author(globex), "Globex Atlas", "111")
    shared.isbn.should eq(Tenancy.with(acme) { Book.query.first!.isbn })
  end

  it "reports a duplicate within one tenant on its field" do
    acme, _ = two_tenants
    author = TenancySpec.author(acme)
    duplicate = Tenancy.with(acme) do
      Book.create(title: "Copy", isbn: "111", author_id: author.id)
    end
    duplicate.errors.should eq({"isbn" => [SugarORM::Wording.taken]})
  end
end

describe "A foreign key between tenanted schemas" do
  it "refuses a changeset that references another tenant's row" do
    acme, globex = two_tenants
    stranger = TenancySpec.author(globex, "Stranger")
    expect_raises(PQ::PQError, "fk_books_author_id") do
      SugarORM::Repo.transaction do
        Tenancy.with(acme) { Book.create(title: "Cross", isbn: "333", author_id: stranger.id) }
      end
    end
  end

  it "refuses raw SQL that references another tenant's row" do
    acme, globex = two_tenants
    stranger = TenancySpec.author(globex, "Stranger")
    insert = "INSERT INTO books (account_id, title, isbn, author_id) VALUES ($1, $2, $3, $4)"
    expect_raises(PQ::PQError, "fk_books_author_id") do
      SugarORM::Repo.transaction do
        SugarORM.sql_exec(insert, acme.id, "Cross", "333", stranger.id)
      end
    end
  end
end
