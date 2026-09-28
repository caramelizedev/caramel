require "spec"
require "../../src/sugar_orm"
require "../../src/caramel/validate_url"
require "../../src/caramel/response"

module ValidateURLSpec
  struct Link < SugarORM::Schema
    schema "validate_url_links" do
      field id : Int64, primary: true
      field destination : String
      field note : String?
    end
  end

  class LinkChangeset < SugarORM::Changeset(Link)
    param destination : String
    param note : String?

    def validate(cs)
      cs.validate_url(:destination)
      cs.validate_url(:note, message: "is not a link")
    end
  end
end

describe "SugarORM::Changeset#validate_url" do
  it "accepts exactly the URLs redirect_external redirects to" do
    request = HTTP::Request.new("GET", "/go")
    ["https://example.com/a?b=1", "http://example.com", "/local", "//example.com", "javascript:alert(1)", "ftp://example.com/x",
     "https://", "https://user:pass@example.com/", "https://example.com/a b", "https://example.com/\r\nX: y"].each do |url|
      redirects = begin
        Caramel::Response.redirect_external(request, url)
        true
      rescue ArgumentError
        false
      end
      ValidateURLSpec::LinkChangeset.new(destination: url).valid?.should eq(redirects)
    end
  end

  it "reports a changed value that is not an external URL on its field, and skips nil" do
    ValidateURLSpec::LinkChangeset.new(destination: "/local").errors.should eq({"destination" => ["must be an absolute http or https URL"]})
    ValidateURLSpec::LinkChangeset.new(destination: "https://example.com", note: "nope").errors.should eq({"note" => ["is not a link"]})
    ValidateURLSpec::LinkChangeset.new(destination: "https://example.com", note: nil).valid?.should be_true
  end
end
