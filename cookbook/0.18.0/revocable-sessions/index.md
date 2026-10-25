Cookbook / Accounts and access

# Sign users in with revocable sessions.

The signed cookie carries a random token. PostgreSQL holds its digest, expiry and revocation, and every request rechecks them.

Proved by scripts/check page-sessions · Target: 0.18.0

| Contract | Value |
| --- | --- |
| Needs | A Caramel installation set up as in [Your first application](https://caramelize.dev/docs/0.18.0/getting-started/index.md); the recipe creates `clubhouse` and its `App::Account` tenant with `frappe make tenancy` ([Multi-tenancy](https://caramelize.dev/docs/0.18.0/multi-tenancy/index.md)) |
| You will have | Login and logout over a revocable token row, per-request `current_session`, `current_user` and `current_membership` readers, a membership guard on tenant pages, and a request spec for expiry, revocation, deactivation, removed membership, replayed cookies and 72-byte passwords |
| Status | Run end to end by `scripts/check page-sessions` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-sessions-files}

- `app/models/user.cr`: Email, digest, active flag
- `app/models/user_session.cr`: Revocable token row
- `app/models/membership.cr`: User-to-account join
- `db/migrations/`: Tables from the diff
- `app/actions/sessions/new.cr`: Show the form
- `app/actions/sessions/login.cr`: Create the session
- `app/actions/sessions/logout.cr`: Revoke the session
- `config/routes.cr`: Login and logout routes
- `app/views/sessions/new.cr`: Sign-in form
- `app/views/layouts/application.cr`: Sign-out form in header
- `app/actions/application_action.cr`: Memoized session readers
- `app/actions/accounts/home.cr`: Member-only home
- `app/actions/accounts/create.cr`: Creator becomes member
- `spec/support/sessions.cr`: Shared builders
- `spec/requests/sessions_spec.cr`: Lifecycle examples
- `spec/requests/accounts_spec.cr`: Sign-up, signed in

## Create the application and its tenant {#c-sessions-start}

The application is `clubhouse`. Its pages live under an account’s slug, so the tenant comes first; the generator also writes the `account(db, slug)` spec helper the examples below use.

1. **Create the application**

   **Terminal · after machine setup**

   ```bash
   frappe new clubhouse
   cd clubhouse
   ```

   **Expect:** Prints `Created clubhouse.`, then `clubhouse is configured at https://clubhouse.caramel`.
2. **Make Account the tenant**

   **Terminal · inside the application**

   ```bash
   frappe make tenancy Account
   ```

   **Expect:** Prints `Generated PATH` for each file it writes or edits, `app/models/account.cr`, `app/actions/accounts/create.cr` and `spec/requests/accounts_spec.cr` among them, then `Next: run frappe migrate and open /accounts/new.`
3. **Apply the tenant’s migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## Keep the revocable part in PostgreSQL {#c-sessions-split}

A cookie that holds `user_id` cannot be revoked: `Caramel::Session` is a signed cookie with no server-side expiry (see [Security](https://caramelize.dev/docs/0.18.0/security/index.md)), so a copy of it stays valid until the browser drops it. Put a random token in the cookie instead and keep its SHA-256 digest, an expiry and a revocation time in a table. Each request looks the digest up, so ending the row ends the session.

An `App::User` has an email, a bcrypt digest and an `active` flag. `App::UserSession` is the revocable row. `App::Membership` joins a user to an account, unique per pair; the guard below reads it. All three are central tables: they declare no `tenant`.

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

1. **Derive the migration**

   **Terminal · inside the application**

   ```bash
   frappe db diff --name create_user_sessions
   ```

   **Expect:** Prints `Wrote db/migrations/…_create_user_sessions.cr`: one migration that creates `users`, `user_sessions` and `memberships`.
2. **Apply the migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`

The digest is unique, so one lookup finds one row.

## Create the session at login, revoke it at logout {#c-sessions-login}

Login is `POST /login` with an `email` and a `password`. Every attempt runs exactly one bcrypt comparison: a missing user is checked against a fixed dummy digest. That keeps the answer and the work comparable, so the response does not say which emails exist; it does not make the timing identical.

| Condition | Outcome |
| --- | --- |
| Unknown email | answers 422, the same page |
| Inactive user | answers 422, the same page |
| Wrong password | answers 422, the same page |
| Password of 72 bytes or more | answers 422, the same page |
| Valid password for an active user | revokes the row behind any token the cookie holds, clears the session, creates a new token and redirects to `/` |

Crystal’s bcrypt reads at most 71 bytes of a password and `verify` raises `Crypto::Bcrypt::Error` from 72 bytes up; without the action’s own test that would answer 500, and only for an email that exists. A contract `max:` counts characters, not bytes, so the action tests `bytesize` itself. The success path revokes the old row because `session.clear` would otherwise orphan a row that stays valid for anyone who copied the old cookie. Only the token’s digest reaches the database.

**app/actions/sessions/new.cr**

```crystal
module App::Sessions
  # The sign-in form, at GET /login.
  struct New < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Sign in", Views::Sessions::New.new(csrf_token, false)
    end
  end
end
```

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
      fits = contract.password.bytesize < 72
      digest = user ? user.password_digest : DUMMY_DIGEST
      matches = Crypto::Bcrypt::Password.new(digest).verify(fits ? contract.password : "")
      unless user && matches && fits
        self.status = 422
        return false
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

The three routes are central: they go in `config/routes.cr` above `# Frappé resource routes`, outside the `tenant` block.

**config/routes.cr · in the central block**

```crystal
get "/login", App::Sessions::New
post "/login", App::Sessions::Login
post "/logout", App::Sessions::Logout
```

1. **List the routes**

   **Terminal · inside the application**

   ```bash
   frappe routes login
   ```

   **Expect:** Prints `GET /login App::Sessions::New` and `POST /login App::Sessions::Login email:String password:String`; `frappe routes logout` prints `POST /logout App::Sessions::Logout`.

`Sessions::New` renders the form below. Both forms turn boosting off with `"hx-boost": "false"` and carry the hidden `_csrf` field. Signing in or out changes the header, which sits outside `#content`, and a boosted swap would leave it stale; a full page load refreshes it.

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

The layout is the generated one with two changes: `initialize` takes `@signed_in : Bool`, and the header shows the sign-out form when it is true. A view cannot call the action’s readers, so the action passes the state in; the next section shows the `layout` override that does.

**app/views/layouts/application.cr**

```crystal
module App::Views::Layouts
  class Application < App::ApplicationView
    def initialize(@page : Caramel::Page, @csrf_token : String, @signed_in : Bool)
    end

    private def blueprint
      doctype
      html lang: Caramel.language do
        head do
          meta charset: "utf-8"
          meta name: "viewport", content: "width=device-width, initial-scale=1"
          title { "#{@page.title} · #{App::TITLE}" }
          link rel: "stylesheet", href: "/assets/app.css"
          script src: "/assets/htmx-4.0.0.min.js", defer: true
          script src: "/assets/caramel-islands.js", defer: true
          script src: "/assets/app.js", defer: true
        end
        body "hx-boost:inherited": "true", "hx-target:inherited": "#content",
          "hx-swap:inherited": "innerMorph",
          "hx-headers:inherited": {"X-CSRF-Token" => @csrf_token}.to_json do
          header class: "site-header" do
            a href: "/", class: "brand" do
              span(class: "mark", aria_hidden: "true") { "c." }
              plain App::TITLE
            end
            if @signed_in
              form method: "post", action: "/logout", "hx-boost": "false" do
                input type: "hidden", name: "_csrf", value: @csrf_token
                button(type: "submit") { "Sign out" }
              end
            end
            span(class: "made-with") { "Made with Caramel" }
          end
          main(id: "content") { raw @page.html }
          footer { "Make something worth opening." }
        end
      end
    end
  end
end
```

## Load the session once per request {#c-sessions-request}

Replace the generated `App::ApplicationAction` with one that passes the signed-in state to the layout and holds three memoized readers. Each has an explicit `@…_loaded` flag, so a nil result is cached too. `@current_user ||= …` would run the query again on every call of an anonymous request, because nil is falsy.

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

| Reader | Matches |
| --- | --- |
| `current_session` | The token digest, with `revoked_at: nil` and `expires_at` from now on |
| `current_user` | The session’s user, who must be `active` |
| `current_membership` | The user and the tenant’s id |

| Condition | Outcome |
| --- | --- |
| A session is revoked or expires | takes effect on the next request |
| A user is deactivated or a membership removed | takes effect on the next request |
| The next request | queries again, because one action instance serves one request |

The memo lives on the action struct, so pass values, not the action, to helpers and views. `current_membership` reads `tenant`, so call it only from a tenant action.

## Guard tenant pages with ingress {#c-sessions-guard}

A tenant action names an authenticator, and the router answers 401 when it returns false, before the contract binds ([Security](https://caramelize.dev/docs/0.18.0/security/index.md)). Nothing else creates a membership, so the action that creates an account must make its creator the first member, or the guard locks every new account out.

| Condition | Outcome |
| --- | --- |
| Anonymous request to a tenant action with an authenticator | answers 401 before the contract binds |
| Non-member request to such an action | answers 401 before the contract binds |
| Anonymous request to `Accounts::Create` | answers 401 before the contract binds |
| Signed-in user creates an account | saves it, then writes the membership and redirects to `/SLUG` |
| The account fails to save | re-renders the form with 422 and writes no membership |

Replace the generated `Accounts::Home` with one that admits members only. The tenant’s routes still sit in the `tenant` block.

**app/actions/accounts/home.cr**

```crystal
module App::Accounts
  # The account's home page, at /SLUG, for its members.
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

The generated `Accounts::Create` redirects to the new account without a membership. Replace it so that only a signed-in user creates an account and becomes its member. The generated `spec/requests/accounts_spec.cr` created an account anonymously and would now get 401; the last section replaces it.

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
      # signed_in? ran before the contract bound, so current_user is a User.
      user = current_user.as(User)
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

## Test the lifecycle in Corretto {#c-sessions-tests}

Corretto’s `client.sign_in(user)` writes only `user_id` into the session cookie, which this guard ignores, so the examples log in through `/login` ([Corretto reference →](https://caramelize.dev/docs/0.18.0/corretto/index.md)). The builders they share live in one module.

| To test | Do this |
| --- | --- |
| Login | Log in through the real route and follow its redirect |
| `client.sign_in(user)` alone | It writes only `user_id`, so a member page answers 401 |
| Expiry | Move `expires_at` into the past with `update!` |
| Replay | Save the cookie before logout and restore it into `client.cookies` afterwards; the same trick proves that a second login revokes the first session |
| 72-byte password | It must get the same page as a wrong one |
| Account creation | It must make its creator a member |

**spec/support/sessions.cr**

```crystal
require "crypto/bcrypt/password"

# Builders the session specs share: a user, a member of an account, a login.
module SessionsSpec
  extend self

  def user(db, active = true) : App::User
    digest = Crypto::Bcrypt::Password.create("secret", cost: 4).to_s
    App::User.create!(db, email: "ann@example.com", password_digest: digest, active: active)
  end

  def member(db, account : App::Account, active = true) : App::User
    user = user(db, active)
    App::Membership.create!(db, user_id: user.id, account_id: account.id)
    user
  end

  def log_in(client, password = "secret") : Caramel::Response
    client.post("/login", params: {"email" => "ann@example.com", "password" => password})
  end
end
```

**spec/requests/sessions_spec.cr**

```crystal
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
```

The generated sign-up spec keeps its form, 404 and reserved-slug examples; the one that created an account anonymously is now the last example above, and the reserved slug is tried signed in.

**spec/requests/accounts_spec.cr · replaces the generated spec**

```crystal
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
```

The specs create their users directly, so the recipe has no sign-up for users: add a registration action, or insert users with a script, before real people can sign in. Expired and revoked rows are never deleted, and no login rate limit is set.

Prove it

## Prove the session lifecycle {#c-sessions-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` exits 0. `frappe corretto` runs the ten session examples (sign in and out, a wrong password, a 72-byte password, `sign_in` alone refused, an expired session, a deactivated user, a deleted membership, a replayed cookie, a second login revoking the first, and account creation making its creator a member) beside the three sign-up examples and the generated home example, and ends with `Corretto: 1 of 1 workers passed`. `frappe lint` exits 0.

> Proved **Run end to end by a check.**
>
> `scripts/check page-sessions` creates `clubhouse`, makes Account its tenant, migrates, copies these files at the steps above, derives and applies the migration, lists the routes and runs the proof, and the website build holds every snippet on this page to those files.

[← All recipes](https://caramelize.dev/cookbook/0.18.0/) · [Test the HTML your app returns →](https://caramelize.dev/docs/0.18.0/testing-html/index.md)

Caramel 0.18.0 · https://caramelize.dev/cookbook/0.18.0/revocable-sessions/
