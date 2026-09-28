module App
  struct @@MODEL@@ < SugarORM::Schema
    schema "@@PLURAL@@" do
      field id : Int64, primary: true
@@MODEL_FIELDS@@
      timestamps@@INDEXES@@
    end
  end
end
