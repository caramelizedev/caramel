module App
  # The tenant: every page under /SLUG belongs to one @@LABEL@@.
  struct @@MODEL@@ < SugarORM::Schema
    schema "@@PLURAL@@" do
      field id : @@ID@@, primary: true
      field name : String
      field slug : String
      timestamps
      index :slug, unique: true
      json :id, :name, :slug, :created_at, :updated_at
    end
  end
end
