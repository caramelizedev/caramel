require "../spec_helper"

describe "@@COLLECTION_LABEL@@" do
  it "@@SPEC_TITLE@@" do
    Corretto.session do |client, db|
      # frappe:only new
      client.get("/@@PLURAL@@/new").should render_page("New @@LABEL@@")
      # frappe:end
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
      # frappe:only index
      client.get("/@@PLURAL@@").should render_page("@@COLLECTION_LABEL@@")
      # frappe:end
      # frappe:only edit
      client.get("#{path}/edit").should render_page("Edit @@LABEL@@")
      # frappe:end
      # frappe:only update
      updated = client.patch(path, headers: {"HX-Request" => "true"}, params: {@@UPDATED_FIELDS@@})
      updated.should have_status(200)
      updated.should have_header("HX-Location", path)
      # frappe:end
      persisted = App::@@MODEL@@.query.find!(db, record.id)
      # frappe:only update
@@ASSERT_FIELDS@@
      # frappe:end
@@ASSERT_CHANGESET@@
      # frappe:only destroy
      client.delete(path, headers: {"X-CSRF-Token" => "forged"}).should have_status(403)
      client.delete(path, headers: {"Origin" => "https://attacker.example"}).should have_status(403)
      # frappe:else
      sample = {@@SAMPLE_FIELDS@@}
      forged = {"X-CSRF-Token" => "forged"}
      foreign = {"Origin" => "https://attacker.example"}
      client.post("/@@PLURAL@@", headers: forged, params: sample).should have_status(403)
      client.post("/@@PLURAL@@", headers: foreign, params: sample).should have_status(403)
      # frappe:end
      db.should have_row(App::@@MODEL@@, id: record.id)
      # frappe:only update
      rejected = client.patch(path, headers: {"HX-Request-Type" => "partial"}, params: {@@UPDATED_FIELDS@@, "unexpected_field" => "refuse"})
      # frappe:else
      partial = {"HX-Request-Type" => "partial"}
      stray = {@@SAMPLE_FIELDS@@, "unexpected_field" => "refuse"}
      rejected = client.post("/@@PLURAL@@", headers: partial, params: stray)
      # frappe:end
      rejected.should have_status(422)
      # frappe:only update
      rejected.should_not render_page("Edit @@LABEL@@")
      # frappe:else
      rejected.should_not render_page("New @@LABEL@@")
      # frappe:end
      rejected.body.should contain("Unknown field: unexpected_field")
      # frappe:only destroy
      # frappe:only index
      client.delete(path).should redirect_to("/@@PLURAL@@")
      # frappe:else
      client.delete(path).should redirect_to("/")
      # frappe:end
      db.should_not have_row(App::@@MODEL@@, id: record.id)
      client.get(path).should have_status(404)
      # frappe:end
    end
  end
end
