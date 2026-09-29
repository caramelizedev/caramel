require "../spec_helper"

describe "@@COLLECTION_LABEL@@" do
  it "@@SPEC_TITLE@@" do
    Corretto.session do |client, db|
      client.get("/@@PLURAL@@/new").should render_page("New @@LABEL@@") # frappe:only=new
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
      client.get("/@@PLURAL@@").should render_page("@@COLLECTION_LABEL@@") # frappe:only=index
      client.get("#{path}/edit").should render_page("Edit @@LABEL@@") # frappe:only=edit
      updated = client.patch(path, headers: {"HX-Request" => "true"}, params: {@@UPDATED_FIELDS@@}) # frappe:only=update
      updated.should have_status(200) # frappe:only=update
      updated.should have_header("HX-Location", path) # frappe:only=update
      persisted = App::@@MODEL@@.query.find!(db, record.id)
@@ASSERT_FIELDS@@ # frappe:only=update
@@ASSERT_CHANGESET@@
      client.delete(path, headers: {"X-CSRF-Token" => "forged"}).should have_status(403) # frappe:only=destroy
      client.delete(path, headers: {"Origin" => "https://attacker.example"}).should have_status(403) # frappe:only=destroy
      client.post("/@@PLURAL@@", headers: {"X-CSRF-Token" => "forged"}, params: {@@SAMPLE_FIELDS@@}).should have_status(403) # frappe:unless=destroy
      client.post("/@@PLURAL@@", headers: {"Origin" => "https://attacker.example"}, params: {@@SAMPLE_FIELDS@@}).should have_status(403) # frappe:unless=destroy
      db.should have_row(App::@@MODEL@@, id: record.id)
      rejected = client.patch(path, headers: {"HX-Request-Type" => "partial"}, params: {@@UPDATED_FIELDS@@, "unexpected_field" => "refuse"}) # frappe:only=update
      rejected = client.post("/@@PLURAL@@", headers: {"HX-Request-Type" => "partial"}, params: {@@SAMPLE_FIELDS@@, "unexpected_field" => "refuse"}) # frappe:unless=update
      rejected.should have_status(422)
      rejected.should_not render_page("Edit @@LABEL@@") # frappe:only=update
      rejected.should_not render_page("New @@LABEL@@") # frappe:unless=update
      rejected.body.should contain("Unknown field: unexpected_field")
      client.delete(path).should redirect_to("@@AFTER_DESTROY@@") # frappe:only=destroy
      db.should_not have_row(App::@@MODEL@@, id: record.id) # frappe:only=destroy
      client.get(path).should have_status(404) # frappe:only=destroy
    end
  end
end
