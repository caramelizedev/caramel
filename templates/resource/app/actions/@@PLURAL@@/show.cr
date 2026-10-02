module App::@@COLLECTION@@
  struct Show < App::ApplicationAction
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
      {record: record}
    end

    def render(result)
      # frappe:only locales
      page t.@@PLURAL@@.model, Views::@@COLLECTION@@::Show.new(result[:record], csrf_token)
      # frappe:else
      page "@@MODEL@@", Views::@@COLLECTION@@::Show.new(result[:record], csrf_token)
      # frappe:end
    end
  end
end
