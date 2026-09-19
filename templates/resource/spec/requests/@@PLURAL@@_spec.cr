require "../spec_helper"

describe "@@COLLECTION_LABEL@@" do
  it "creates, reads, updates and deletes through CSRF-protected browser forms" do
    app = App.build(SPEC_DB, "s" * 64, "https://@@HOST@@")
    headers = HTTP::Headers{"Host" => "@@HOST@@"}
    page = app.handle(HTTP::Request.new("GET", "/@@PLURAL@@/new", headers))
    page.status.should eq(200)
    cookie = page.headers["Set-Cookie"].split(';').first
    token = cookie.split('=', 2).last
    headers["Cookie"] = cookie
    headers["Origin"] = "https://@@HOST@@"
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    values = {@@SAMPLE_FIELDS@@}
    values["_csrf"] = token
    created = app.handle(HTTP::Request.new("POST", "/@@PLURAL@@", headers, URI::Params.encode(values)))
    created.status.should eq(303)
    path = created.headers["Location"]
    id = path.split('/').last.to_i64
    begin
      App::@@MODEL@@.find(id).should_not be_nil
      shown = app.handle(HTTP::Request.new("GET", path, headers))
      shown.status.should eq(200)
@@ASSERT_ESCAPING@@
      app.handle(HTTP::Request.new("GET", "/@@PLURAL@@", headers)).status.should eq(200)
      app.handle(HTTP::Request.new("GET", path + "/edit", headers)).status.should eq(200)
      values["_method"] = "PATCH"
      values.merge!({@@UPDATED_FIELDS@@})
      headers["HX-Request"] = "true"
      updated = app.handle(HTTP::Request.new("POST", path, headers, URI::Params.encode(values)))
      updated.status.should eq(200)
      updated.headers["HX-Location"].should eq(path)
      persisted = App::@@MODEL@@.find(id).not_nil!
@@ASSERT_FIELDS@@
      headers.delete("HX-Request")
      forged = values.merge({"_csrf" => "invalid", "_method" => "DELETE"})
      app.handle(HTTP::Request.new("POST", path, headers, URI::Params.encode(forged))).status.should eq(403)
      App::@@MODEL@@.find(id).should_not be_nil
      invalid = values.merge({"unexpected_field" => "refuse"})
      headers["HX-Request-Type"] = "partial"
      rejected = app.handle(HTTP::Request.new("POST", path, headers, URI::Params.encode(invalid)))
      rejected.status.should eq(422)
      rejected.body.should_not contain("<!DOCTYPE")
      rejected.body.should contain("Unknown form field")
      headers.delete("HX-Request-Type")
      deleted = app.handle(HTTP::Request.new("POST", path, headers, URI::Params.encode({"_csrf" => token, "_method" => "DELETE"})))
      deleted.status.should eq(303)
      App::@@MODEL@@.find(id).should be_nil
      app.handle(HTTP::Request.new("GET", path, headers)).status.should eq(404)
    ensure
      App::@@MODEL@@.find(id).try(&.delete)
    end
  end
end
