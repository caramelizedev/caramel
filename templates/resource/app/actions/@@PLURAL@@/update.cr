module App::@@COLLECTION@@
  struct Update < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
@@ASSIGNMENTS@@
      return render_form(contract.values, record.errors, contract.id, 422) unless record.save
      {record: record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id.not_nil!))
    end
  end
end
