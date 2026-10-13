Cookbook / Accounts and access

# Sign users in with revocable sessions.

The signed cookie carries a random token. PostgreSQL holds its digest, expiry and revocation, and every request rechecks them.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

## Keep the revocable part in PostgreSQL {#c-session-split}

A cookie that holds `user_id` cannot be revoked: `Caramel::Session` is a signed cookie with no server-side expiry (see [Security](https://caramelize.dev/docs/0.14.0/security/index.md)), so a copy of it stays valid until the browser drops it. Put a random token in the cookie instead and keep its SHA-256 digest, an expiry and a revocation time in a table. Each request looks the digest up, so ending the row ends the session.

An `App::User` has an email, a bcrypt digest and an `active` flag. `App::UserSession` is the revocable row. Both are central tables: they declare no `tenant`.

**app/models/user.cr**

```crystal
module App
  struct User < SugarORM::Schema
    schema "users" do
      field id : Int64, primary: true
      field email : String
      field password_digest : String
      field active : Bool = true
      timestamps
      index :email, unique: true
    end
  end
end
```

**app/models/user_session.cr**

```crystal
module App
  struct UserSession < SugarORM::Schema
    schema "user_sessions" do
      field id : Int64, primary: true
      belongs_to user : User
      field token_digest : String
      field expires_at : Time
      field revoked_at : Time?
      timestamps
      index :token_digest, unique: true
    end
  end
end
```

**Terminal**

```bash
frappe db diff --name create_user_sessions
frappe migrate
```

The diff writes one migration for every table the schemas declare that the database lacks, so a first run also creates `users` and the `memberships` table below. The digest is unique, so one lookup finds one row.

## Create the session at login, revoke it at logout {#c-session-login}

Login is `POST /login` with an `email` and a `password`. An unknown email, an inactive user, a wrong password and an over-long password all get the same 422 page, and every attempt runs exactly one bcrypt comparison: a missing user is checked against a fixed dummy digest. That keeps the answer and the work comparable, so the response does not say which emails exist; it does not make the timing identical.

Crystal’s bcrypt reads at most 71 bytes of a password and `verify` raises `Crypto::Bcrypt::Error` from 72 bytes up. A contract `max:` counts characters, not bytes, so the action tests `bytesize` itself; without that test a long password would answer 500 only for an email that exists. On success the action revokes the row behind any token the cookie already holds, because `session.clear` would otherwise orphan a row that stays valid for anyone who copied the old cookie. It then clears the session and creates the new token. Only the token’s digest reaches the database.

**app/actions/sessions/login.cr**

```crystal
require "crypto/bcrypt/password"
require "digest/sha256"

module App::Sessions
  struct Login < App::ApplicationAction
    # A valid bcrypt digest that no password matches. An unknown or inactive
    # email is checked against it, so every attempt costs one bcrypt comparison.
    DUMMY_DIGEST = "$2a$11$gAYJo.vJfIwsu1p8HuehU.GEPrMMm4NrGSBZIZiDHdZVg.JHmm5wi"

    contract do
      field email : String
      field password : String
    end

    def handle(contract : Contract)
      user = User.query.where(email: contract.email, active: true).first
      # bcrypt reads at most 71 bytes: verify raises for 72 or more, which would
      # answer 500 only for an existing email. Treat those as a wrong password.
      too_long = contract.password.bytesize >= 72
      digest = user ? user.password_digest : DUMMY_DIGEST
      matches = Crypto::Bcrypt::Password.new(digest).verify(too_long ? "" : contract.password)
      unless user && matches && !too_long
        self.status = 422
        return nil
      end
      # A cookie that still holds a session token must not leave its row open.
      current_session.try &.update!(revoked_at: Time.utc)
      session.clear
      token = Random::Secure.urlsafe_base64(32)
      UserSession.create!(
        user_id: user.id,
        token_digest: Digest::SHA256.hexdigest(token),
        expires_at: Time.utc + 14.days)
      session["session_token"] = token
      true
    end

    def render(result)
      return page "Sign in", Views::Sessions::New.new(csrf_token, true) unless result
      redirect_to "/"
    end
  end
end
```

Logout is `POST /logout`. It marks the current row revoked before `sign_out` clears the cookie, so a copy of the old cookie no longer matches an open row.

**app/actions/sessions/logout.cr**

```crystal
module App::Sessions
  struct Logout < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      current_session.try &.update!(revoked_at: Time.utc)
      sign_out
      true
    end

    def render(result)
      redirect_to "/login"
    end
  end
end
```

Route them with `get "/login"`, `post "/login"` and `post "/logout"` in the central part of `config/routes.cr`. `Sessions::New` renders the form below. Both forms turn boosting off with `"hx-boost": "false"` and carry the hidden `_csrf` field. Signing in or out changes the header, which sits outside `#content`, and a boosted swap would leave it stale; a full page load refreshes it.

**app/views/sessions/new.cr**

```crystal
module App::Views::Sessions
  class New < App::ApplicationView
    def initialize(@csrf_token : String, @failed : Bool)
    end

    private def blueprint
      h1 { "Sign in" }
      p { "Email or password is wrong." } if @failed
      form method: "post", action: "/login", "hx-boost": "false" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        label { "Email" }
        input type: "email", name: "email", required: true
        label { "Password" }
        input type: "password", name: "password", required: true
        button(type: "submit") { "Sign in" }
      end
    end
  end
end
```

**app/views/layouts/application.cr · logout form in the header**

```crystal
if @signed_in
  form method: "post", action: "/logout", "hx-boost": "false" do
    input type: "hidden", name: "_csrf", value: @csrf_token
    button(type: "submit") { "Sign out" }
  end
end
```

The layout receives the signed-in state from the action: pass `signed_in: !current_user.nil?` to `Layouts::Application.new` from `layout(page)`, store it as `@signed_in`, and test that, because a view cannot call the action’s helpers.

## Load the session once per request {#c-session-request}

Put three memoized readers on `App::ApplicationAction`. Each has an explicit `@…_loaded` flag, so a nil result is cached too. `@current_user ||= …` would run the query again on every call of an anonymous request, because nil is falsy.

**app/actions/application_action.cr**

```crystal
require "digest/sha256"

module App
  abstract struct ApplicationAction < Caramel::Action
    include App::Paths

    @session_loaded = false
    @current_session : UserSession? = nil
    @user_loaded = false
    @current_user : User? = nil
    @membership_loaded = false
    @current_membership : Membership? = nil

    def layout(page : Caramel::Page) : String
      Views::Layouts::Application.new(page, csrf_token, signed_in: !current_user.nil?).to_s
    end

    def title_for(page : Caramel::Page) : String
      "#{page.title} · #{App::TITLE}"
    end

    def current_session : UserSession?
      unless @session_loaded
        @session_loaded = true
        if token = session["session_token"]?
          @current_session = UserSession.query.where(
            token_digest: Digest::SHA256.hexdigest(token),
            revoked_at: nil,
            expires_at: Time.utc..
          ).first
        end
      end
      @current_session
    end

    def current_user : User?
      unless @user_loaded
        @user_loaded = true
        if user_session = current_session
          @current_user = User.query.where(id: user_session.user_id, active: true).first
        end
      end
      @current_user
    end

    def current_membership : Membership?
      unless @membership_loaded
        @membership_loaded = true
        if user = current_user
          @current_membership = Membership.query
            .where(user_id: user.id, account_id: tenant.id).first
        end
      end
      @current_membership
    end
  end
end
```

`current_session` matches the digest with `revoked_at: nil` and `expires_at` from now on. `current_user` requires `active`. `current_membership` matches the user and the tenant’s id. One action instance serves one request, so the next request queries again: that is why revocation, expiry, deactivation and a removed membership take effect on the next request. The memo lives on the action struct, so pass values, not the action, to helpers and views.

## Guard tenant pages with ingress {#c-session-guard}

A tenant action names an authenticator. An anonymous or non-member request answers 401 before the contract binds. The membership is a central table that joins a user to an account, unique per pair. Nothing else creates one, so the action that creates an account must make its creator the first member, or the guard locks every new account out.

**app/models/membership.cr**

```crystal
module App
  struct Membership < SugarORM::Schema
    schema "memberships" do
      field id : Int64, primary: true
      belongs_to user : User
      belongs_to account : Account
      timestamps
      index :user_id, :account_id, unique: true
    end
  end
end
```

**app/actions/accounts/home.cr**

```crystal
module App::Accounts
  # The account's home page, at /SLUG.
  struct Home < App::ApplicationAction
    ingress authenticate: :member?

    contract do
    end

    def handle(contract : Contract)
      page tenant.name, Views::Accounts::Home.new(tenant)
    end

    private def member? : Bool
      !current_membership.nil?
    end
  end
end
```

Ingress is covered in [the webhook recipe](https://caramelize.dev/cookbook/0.14.0/webhooks/index.md). The tenant’s routes still sit in the `tenant` block.

The generated `Accounts::Create` redirects to the new account without a membership. Replace it so that only a signed-in user creates an account and becomes its member. The membership is written after the account is saved; a failed account re-renders the form and writes nothing. The signed-in check runs before the contract binds, so an anonymous request answers 401. The generated spec that created an account anonymously no longer applies; the spec below covers sign-up.

**app/actions/accounts/create.cr**

```crystal
module App::Accounts
  struct Create < App::ApplicationAction
    include Form

    # Only a signed-in user creates an account, and becomes its first member.
    ingress authenticate: :signed_in?

    contract do
      field name : String
      field slug : String
    end

    def handle(contract : Contract)
      user = current_user.not_nil!
      changes = App::Account.create(name: contract.name, slug: contract.slug)
      return render_form(contract.values, changes.errors, 422) unless changes.saved?
      App::Membership.create!(user_id: user.id, account_id: changes.record.id)
      self.status = 201
      {record: changes.record}
    end

    def render(result)
      redirect_to("/#{result[:record].slug}")
    end

    private def signed_in? : Bool
      !current_user.nil?
    end
  end
end
```

## Test the lifecycle in Corretto {#c-session-tests}

Log in through the real route and follow its redirect. `client.sign_in(user)` writes only `user_id`, so on its own it gets 401 on a member page. Move `expires_at` into the past with `update!` to test expiry. To test a replay, save the cookie before logout and restore it into `client.cookies` afterwards; the same trick proves that a second login revokes the first session. A 72-byte password must get the same page as a wrong one, and creating an account must make its creator a member.

**spec/requests/sessions_spec.cr**

```crystal
require "../spec_helper"
require "crypto/bcrypt/password"

def user(db, active = true) : App::User
  digest = Crypto::Bcrypt::Password.create("secret", cost: 4).to_s
  App::User.create!(db, email: "ann@example.com", password_digest: digest, active: active)
end

def member(db, account : App::Account, active = true) : App::User
  user = user(db, active)
  App::Membership.create!(db, user_id: user.id, account_id: account.id)
  user
end

def log_in(client, password = "secret")
  client.post("/login", params: {"email" => "ann@example.com", "password" => password})
end

describe "Revocable sessions" do
  it "signs a member in and out" do
    Corretto.session do |client, db|
      acme = account(db, "acme")
      member(db, acme)
      log_in(client).should redirect_to("/")
      client.get("/acme").should have_status(200)
      client.post("/logout").should redirect_to("/login")
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a wrong password" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      log_in(client, "wrong").should have_status(422)
      client.get("/acme").should have_status(401)
    end
  end

  it "answers a password of 72 bytes or more like a wrong one" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      wrong = log_in(client, "wrong")
      long = log_in(client, "a" * 72)
      long.should have_status(422)
      long.body.should eq(wrong.body)
      client.get("/acme").should have_status(401)
    end
  end

  it "does not accept sign_in alone" do
    Corretto.session do |client, db|
      user = member(db, account(db, "acme"))
      client.sign_in(user)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses an expired session" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      log_in(client)
      client.get("/acme").should have_status(200)
      App::UserSession.query.first!.update!(db, expires_at: Time.utc - 1.minute)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a deactivated user" do
    Corretto.session do |client, db|
      user = member(db, account(db, "acme"))
      log_in(client)
      user.update!(db, active: false)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a user whose membership was deleted" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      log_in(client)
      client.get("/acme").should have_status(200)
      App::Membership.query.first!.delete(db)
      client.get("/acme").should have_status(401)
    end
  end

  it "refuses a replayed cookie after logout" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      log_in(client)
      cookie = client.cookies[Caramel::Session::COOKIE_NAME]
      client.post("/logout")
      client.cookies[Caramel::Session::COOKIE_NAME] = cookie
      client.get("/acme").should have_status(401)
    end
  end

  it "revokes the earlier session when a signed-in browser logs in again" do
    Corretto.session do |client, db|
      member(db, account(db, "acme"))
      log_in(client)
      first = client.cookies[Caramel::Session::COOKIE_NAME]
      log_in(client).should redirect_to("/")
      client.get("/acme").should have_status(200)
      client.cookies[Caramel::Session::COOKIE_NAME] = first
      client.get("/acme").should have_status(401)
    end
  end

  it "makes the creator of an account its member" do
    Corretto.session do |client, db|
      user(db)
      client.post("/accounts", params: {"name" => "Acme", "slug" => "acme"})
        .should have_status(401)
      log_in(client)
      client.post("/accounts", params: {"name" => "Acme", "slug" => "acme"})
        .should redirect_to("/acme")
      client.follow_redirect.should render_page("Acme")
    end
  end
end
```

> **Corretto’s sign_in stores user_id**
>
> `client.sign_in(user)` writes `user_id` into the session cookie. An application whose guard reads a session token ignores it, so tests of such an application log in through `/login`. The specs create their users directly, so the recipe’s own sign-up has no seeded user; add a registration action, or insert users with a script, before real people can sign in.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/revocable-sessions/
