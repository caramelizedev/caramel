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
