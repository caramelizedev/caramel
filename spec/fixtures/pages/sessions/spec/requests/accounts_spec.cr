require "../spec_helper"
require "../support/sessions"

describe "Account sign-up" do
  it "renders the sign-up form" do
    Corretto.session do |client|
      client.get("/accounts/new").should render_page("New account")
    end
  end

  it "answers 404 for a slug no account has" do
    Corretto.session do |client|
      client.get("/globex").should have_status(404)
    end
  end

  it "refuses a slug a central route starts with" do
    Corretto.session do |client, db|
      SessionsSpec.user(db)
      SessionsSpec.log_in(client)
      taken = client.post("/accounts", params: {"name" => "Health", "slug" => "health"})
      taken.should have_status(422)
    end
  end
end
