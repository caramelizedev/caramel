require "../spec_helper"

describe "@@MODEL@@ sign-up" do
  it "renders the sign-up form" do
    Corretto.session do |client|
      client.get("/@@PLURAL@@/new").should render_page("New @@LABEL@@")
    end
  end

  it "creates a @@LABEL@@ whose home is its slug" do
    Corretto.session do |client|
      created = client.post("/@@PLURAL@@", params: {"name" => "Acme", "slug" => "acme"})
      created.should redirect_to("/acme")
      client.follow_redirect.should render_page("Acme")
    end
  end

  it "answers 404 for a slug no @@LABEL@@ has" do
    Corretto.session do |client|
      client.get("/globex").should have_status(404)
    end
  end

  it "refuses a slug a central route starts with" do
    Corretto.session do |client|
      taken = client.post("/@@PLURAL@@", params: {"name" => "Health", "slug" => "health"})
      taken.should have_status(422)
    end
  end
end
