module App
  class @@MODEL@@ < ApplicationRecord
    table :@@PLURAL@@
    field id : Int64?, primary: true
@@MODEL_FIELDS@@
    timestamps
@@PRESENCE@@
  end
end
