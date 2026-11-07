module App
  struct Membership < SugarORM::Schema
    schema "memberships" do
      field id : UUID, primary: true
      belongs_to user : User
      belongs_to account : Account
      timestamps
      index :user_id, :account_id, unique: true
    end
  end
end
