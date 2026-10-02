module App::@@COLLECTION@@
  struct Edit < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      # frappe:only locales
      return not_found(t.@@PLURAL@@.not_found) unless record
      # frappe:else
      return not_found("@@MODEL@@ not found") unless record
      # frappe:end
      values = {@@VALUES@@}
      render_form(values, {} of String => Array(String), contract.id)
    end
  end
end
