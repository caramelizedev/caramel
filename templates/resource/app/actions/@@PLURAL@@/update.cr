module App::@@COLLECTION@@
  struct Update < App::ApplicationAction
    # frappe:only edit
    include Form

    # frappe:end
    contract do
      field id : Int64, min: 1
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
      changes = record.update(@@UPDATE_ATTRIBUTES@@)
      # frappe:only edit
      return render_form(contract.values, changes.errors, contract.id, 422) unless changes.saved?
      # frappe:else
      return render_errors(changes.errors) unless changes.saved?
      # frappe:end
      {record: changes.record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id))
    end
  end
end
