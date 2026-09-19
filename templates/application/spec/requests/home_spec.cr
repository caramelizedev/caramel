require "../spec_helper"

describe "Home" do
  it "renders a full page and a fragment with the same locally served assets" do
    app = App.build(SPEC_DB, "s" * 64, "https://@@NAME@@.@@SUFFIX@@")
    headers = HTTP::Headers{"Host" => "@@NAME@@.@@SUFFIX@@"}
    page = app.handle(HTTP::Request.new("GET", "/", headers))
    page.status.should eq(200)
    page.body.should contain("@@TITLE@@")
    page.body.should contain("/assets/htmx-4.0.0.min.js")
    headers["HX-Request-Type"] = "partial"
    partial = app.handle(HTTP::Request.new("GET", "/", headers))
    partial.status.should eq(200)
    partial.body.should_not contain("<!DOCTYPE")
  end
end
