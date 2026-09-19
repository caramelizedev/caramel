require "spec"
require "../../src/caramel/form_input"
require "../../src/caramel/controller"

struct BookInput
  include Caramel::FormInput
  field title : String
  field author : String
end

struct ScalarInput
  include Caramel::FormInput
  form_envelope "sample"
  field count : Int32
  field total : Int64
  field active : Bool
  field score : Float64?
  field published_at : Time?
  field note : String?
end

private def book_form(body : String) : Caramel::Form
  Caramel::Form.new(body, BookInput.envelope, BookInput.fields, BookInput.required_fields)
end

private def scalar_form(body : String) : Caramel::Form
  Caramel::Form.new(body, ScalarInput.envelope, ScalarInput.fields, ScalarInput.required_fields)
end

describe Caramel::FormInput do
  it "accepts the inherited CSRF header when no hidden token was sent" do
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    token = csrf.issue
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Origin" => "https://bookshelf.caramel", "Cookie" => "__Host-caramel_csrf=#{token}", "X-CSRF-Token" => token}
    request = HTTP::Request.new("POST", "/books", headers, "book[title]=Hello&book[author]=Someone")
    Caramel::Controller.new(request, csrf).parse_form(BookInput).valid?.should be_true
    forged = HTTP::Request.new("POST", "/books", headers, "_csrf=forged&book[title]=Hello&book[author]=Someone")
    expect_raises(Caramel::Forbidden) { Caramel::Controller.new(forged, csrf).parse_form(BookInput) }
  end

  it "infers an envelope and produces a typed value for exactly the declared fields" do
    BookInput.envelope.should eq("book")
    BookInput.fields.should eq(["title", "author"])
    result = BookInput.from_form(book_form("book[title]=Hello+World&book[author]=A%26B"))
    result.valid?.should be_true
    result.value.not_nil!.title.should eq("Hello World")
    result.value.not_nil!.author.should eq("A&B")
    result.errors.should be_empty
    result.values["author"].should eq("A&B")
  end

  it "keeps a blank required string for model validation" do
    result = BookInput.from_form(book_form("book[title]=&book[author]=Someone"))
    result.valid?.should be_true
    result.value.not_nil!.title.should eq("")
  end

  it "rejects missing, duplicate and undeclared fields while keeping submitted text" do
    result = BookInput.from_form(book_form("book[title]=First&book[title]=Second&book[admin]=true"))
    result.valid?.should be_false
    result.value.should be_nil
    result.values["title"].should eq("First")
    result.errors["title"].should contain("Duplicate form field")
    result.errors["author"].should contain("Missing author")
    result.errors["_base"].should contain("Unknown form field")
    result.values.has_key?("admin").should be_false
  end

  it "parses scalars and treats absent or blank nullable fields as nil" do
    ScalarInput.required_fields.should eq(["count", "total", "active"])
    result = ScalarInput.from_form(scalar_form("sample[count]=-23&sample[total]=9223372036854775807&sample[active]=false&sample[score]=&sample[note]=+"))
    result.valid?.should be_true
    input = result.value.not_nil!
    input.count.should eq(-23)
    input.total.should eq(Int64::MAX)
    input.active.should be_false
    input.score.should be_nil
    input.published_at.should be_nil
    input.note.should be_nil
  end

  it "reports all scalar errors without dropping their original text" do
    body = "sample[count]=2147483648&sample[total]=9223372036854775808&sample[active]=yes&sample[score]=NaN&sample[published_at]=yesterday"
    result = ScalarInput.from_form(scalar_form(body))
    result.value.should be_nil
    result.errors.keys.sort.should eq(["active", "count", "published_at", "score", "total"])
    result.values["score"].should eq("NaN")
    result.values["count"].should eq("2147483648")
  end

  it "accepts finite floats and RFC3339 timestamps with an explicit timezone" do
    body = "sample[count]=0&sample[total]=0&sample[active]=true&sample[score]=1.25&sample[published_at]=2026-09-19T14%3A30%3A00%2B02%3A00"
    result = ScalarInput.from_form(scalar_form(body))
    result.valid?.should be_true
    input = result.value.not_nil!
    input.score.should eq(1.25)
    input.published_at.should eq(Time.utc(2026, 9, 19, 12, 30))
    ["1_000", "1.5", "0x10", " 5 ", ""].each do |bad|
      ScalarInput.from_form(scalar_form("sample[count]=#{URI.encode_www_form(bad)}&sample[total]=0&sample[active]=true")).valid?.should be_false
    end
    ["Infinity", "-Infinity", "1e999", "1_000"].each do |bad|
      ScalarInput.from_form(scalar_form("sample[count]=0&sample[total]=0&sample[active]=true&sample[score]=#{bad}")).valid?.should be_false
    end
  end

  it "checks CSRF before returning a typed result, even for invalid input" do
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    token = csrf.issue
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Origin" => "https://bookshelf.caramel", "Cookie" => "__Host-caramel_csrf=#{token}"}
    body = "_csrf=#{token}&book[title]=Hello&book[author]=Someone"
    request = HTTP::Request.new("POST", "/books", headers, body)
    Caramel::Controller.new(request, csrf).parse_form(BookInput).value.not_nil!.title.should eq("Hello")
    bad = HTTP::Request.new("POST", "/books", headers, "_csrf=forged&book[title]=Hello")
    expect_raises(Caramel::Forbidden) { Caramel::Controller.new(bad, csrf).parse_form(BookInput) }
    missing = HTTP::Request.new("POST", "/books", headers, "_csrf=#{token}&book[title]=Hello")
    result = Caramel::Controller.new(missing, csrf).parse_form(BookInput)
    result.valid?.should be_false
    result.errors["author"].should contain("Missing author")
  end
end
