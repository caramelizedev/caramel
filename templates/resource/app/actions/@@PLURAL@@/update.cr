module App::@@COLLECTION@@
  struct Update < App::ApplicationAction
    include Form # frappe:only=edit
    # frappe:only=edit
    contract do
      field id : Int64, min: 1
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
      changes = record.update(@@UPDATE_ATTRIBUTES@@)
      return render_form(contract.values, changes.errors, contract.id, 422) unless changes.saved? # frappe:only=edit
      return render_errors(changes.errors) unless changes.saved? # frappe:unless=edit
      {record: changes.record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id))
    end
  end
end
