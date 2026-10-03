module App
  # The tenant: every page under /SLUG belongs to one @@LABEL@@.
  struct @@MODEL@@ < SugarORM::Schema
    schema "@@PLURAL@@" do
      field id : Int64, primary: true
      field name : String
      field slug : String
      timestamps
      index :slug, unique: true
    end
  end
end
