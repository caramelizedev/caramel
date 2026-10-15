require "../spec_helper"
require "../support/sessions"

describe "Revocable sessions" do
  it "signs a member in and out" do
    Corretto.session do |client, db|
      acme = account(db, "acme")
      SessionsSpec.member(db, acme)
      client.get("/login").should render_page("Sign in")
      SessionsSpec.log_in(client).should redirect_to("/")
      client.get("/acme").should have_status(200)
      client.post("/logout").should redirect_to("/login")
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a wrong password" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client, "wrong").should have_status(422)
      client.get("/acme").should have_status(401)
    end
  end

  it "answers a password of 72 bytes or more like a wrong one" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      wrong = SessionsSpec.log_in(client, "wrong")
      long = SessionsSpec.log_in(client, "a" * 72)
      long.should have_status(422)
      long.body.should eq(wrong.body)
      client.get("/acme").should have_status(401)
    end
  end

  it "does not accept sign_in alone" do
    Corretto.session do |client, db|
      user = SessionsSpec.member(db, account(db, "acme"))
      client.sign_in(user)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses an expired session" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client)
      client.get("/acme").should have_status(200)
      App::UserSession.query.first!.update!(db, expires_at: Time.utc - 1.minute)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a deactivated user" do
    Corretto.session do |client, db|
      user = SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client)
      user.update!(db, active: false)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a user whose membership was deleted" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client)
      client.get("/acme").should have_status(200)
      App::Membership.query.first!.delete(db)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a replayed cookie after logout" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client)
      cookie = client.cookies[Caramel::Session::COOKIE_NAME]
      client.post("/logout")
      client.cookies[Caramel::Session::COOKIE_NAME] = cookie
      client.get("/acme").should have_status(401)
    end
  end

  it "revokes the earlier session when a signed-in browser logs in again" do
    Corretto.session do |client, db|
      SessionsSpec.member(db, account(db, "acme"))
      SessionsSpec.log_in(client)
      first = client.cookies[Caramel::Session::COOKIE_NAME]
      SessionsSpec.log_in(client).should redirect_to("/")
      client.get("/acme").should have_status(200)
      client.cookies[Caramel::Session::COOKIE_NAME] = first
      client.get("/acme").should have_status(401)
    end
  end

  it "makes the creator of an account its member" do
    Corretto.session do |client, db|
      SessionsSpec.user(db)
      client.post("/accounts", params: {"name" => "Acme", "slug" => "acme"})
        .should have_status(401)
      SessionsSpec.log_in(client)
      client.post("/accounts", params: {"name" => "Acme", "slug" => "acme"})
        .should redirect_to("/acme")
      client.follow_redirect.should render_page("Acme")
    end
  end
end
