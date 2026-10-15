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
