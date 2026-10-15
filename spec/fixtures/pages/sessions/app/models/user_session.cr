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
