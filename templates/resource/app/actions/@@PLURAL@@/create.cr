module App::@@COLLECTION@@
  struct Create < App::ApplicationAction
    include Form

    contract do
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.new(@@ATTRIBUTES@@)
      return render_form(contract.values, record.errors, nil, 422) unless record.save
      self.status = 201
      {record: record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id.not_nil!))
    end
  end
end
