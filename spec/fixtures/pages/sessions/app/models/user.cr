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
