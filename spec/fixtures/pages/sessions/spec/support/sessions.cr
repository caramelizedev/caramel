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
