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
