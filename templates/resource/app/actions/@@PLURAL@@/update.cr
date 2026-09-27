module App::@@COLLECTION@@
  struct Update < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
      changes = record.update(@@ATTRIBUTES@@)
      return render_form(contract.values, changes.errors, contract.id, 422) unless changes.saved?
      {record: changes.record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id))
    end
  end
end
