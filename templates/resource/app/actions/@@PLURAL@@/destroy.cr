module App::@@COLLECTION@@
  struct Destroy < App::ApplicationAction
    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      # frappe:only locales
      return not_found(t.@@PLURAL@@.not_found) unless record && record.delete
      # frappe:else
      return not_found("@@MODEL@@ not found") unless record && record.delete
      # frappe:end
      {id: contract.id}
    end

    def render(result)
      # frappe:only index
      redirect_to(@@PLURAL@@_path)
      # frappe:else
      # frappe:only tenant
      redirect_to(tenant_path("/"))
      # frappe:else
      redirect_to("/")
      # frappe:end
      # frappe:end
    end
  end
end
