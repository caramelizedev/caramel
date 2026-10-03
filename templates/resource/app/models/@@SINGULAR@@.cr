module App
  struct @@MODEL@@ < SugarORM::Schema
    schema "@@PLURAL@@" do
      field id : Int64, primary: true
      # frappe:only tenant
      tenant @@TENANT@@ : @@TENANT_MODEL@@
      # frappe:end
@@MODEL_FIELDS@@
      timestamps@@INDEXES@@
    end
  end
end
