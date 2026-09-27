require "../spec_helper"

describe "@@COLLECTION_LABEL@@" do
  it "creates, reads, updates and deletes through CSRF-protected browser forms" do
    Corretto.session do |client, db|
      client.get("/@@PLURAL@@/new").should render_page("New @@LABEL@@")
      created = client.post("/@@PLURAL@@", params: {@@SAMPLE_FIELDS@@})
      record = App::@@MODEL@@.query.order_by(:id, :desc).first!(db)
      path = "/@@PLURAL@@/#{record.id}"
      created.should have_status(303)
      created.should redirect_to(path)
      db.should have_row(App::@@MODEL@@, id: record.id, @@SAMPLE_CONDITIONS@@)
      shown = client.follow_redirect
      shown.should render_page("@@MODEL@@")
@@ASSERT_ESCAPING@@
      json = client.get(path, headers: {"Accept" => "application/json"})
      json.should have_status(200)
      JSON.parse(json.body)["record"]["id"].as_i64.should eq(record.id)
      client.get("/@@PLURAL@@").should render_page("@@COLLECTION_LABEL@@")
      client.get("#{path}/edit").should render_page("Edit @@LABEL@@")
      updated = client.patch(path, headers: {"HX-Request" => "true"}, params: {@@UPDATED_FIELDS@@})
      updated.should have_status(200)
      updated.should have_header("HX-Location", path)
      persisted = App::@@MODEL@@.query.find!(db, record.id)
@@ASSERT_FIELDS@@
@@ASSERT_PRESENCE@@
      client.delete(path, headers: {"X-CSRF-Token" => "forged"}).should have_status(403)
      client.delete(path, headers: {"Origin" => "https://attacker.example"}).should have_status(403)
      db.should have_row(App::@@MODEL@@, id: record.id)
      rejected = client.patch(path, headers: {"HX-Request-Type" => "partial"}, params: {@@UPDATED_FIELDS@@, "unexpected_field" => "refuse"})
      rejected.should have_status(422)
      rejected.should_not render_page("Edit @@LABEL@@")
      rejected.body.should contain("Unknown field: unexpected_field")
      client.delete(path).should redirect_to("/@@PLURAL@@")
      db.should_not have_row(App::@@MODEL@@, id: record.id)
      client.get(path).should have_status(404)
    end
  end
end
