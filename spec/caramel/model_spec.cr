require "spec"
require "../fixtures/models/application_record"

describe Caramel::Model do
  it "defaults nullable fields to nil and keeps ordinary instance state out of the schema" do
    sample = TypedSample.new(name: "Item", quantity: 2, total: 3_i64, active: false)
    sample.score.should be_nil
    sample.note.should be_nil
    sample.published_at.should be_nil
    TypedSample.__caramel_select_list.should_not contain("presentation_cache")
  end

  it "builds a typed record with nil persistence metadata" do
    book = Book.new(title: "A book", author: "An author")

    book.id.should be_nil
    book.created_at.should be_nil
    book.updated_at.should be_nil
    book.title.should eq("A book")
    book.author.should eq("An author")
    book.errors.should be_empty
  end

  it "validates declared presence rules into per-field errors" do
    book = Book.new(title: "", author: "An author")

    book.valid?.should be_false
    book.errors.should eq({"title" => ["must be present"]})

    book.title = "A book"
    book.valid?.should be_true
    book.errors.should be_empty
  end

  it "builds chainable query objects without opening a database" do
    query = Book.where(title: "A book").order(created_at: :desc).limit(1)

    query.should be_a(Caramel::Model::Query(Book))
  end

  it "rejects invalid query directions at runtime" do
    query = Book.where(title: "A book")

    expect_raises(ArgumentError, /direction/) do
      query.order(created_at: :sideways)
    end
  end
end
