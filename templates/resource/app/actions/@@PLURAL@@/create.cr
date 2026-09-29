module App::@@COLLECTION@@
  struct Create < App::ApplicationAction
    include Form # frappe:only=new
    # frappe:only=new
    contract do
@@CONTRACT_FIELDS@@
    end

    def handle(contract : Contract)
      changes = App::@@MODEL@@.create(@@CREATE_ATTRIBUTES@@)
      return render_form(contract.values, changes.errors, nil, 422) unless changes.saved? # frappe:only=new
      return render_errors(changes.errors) unless changes.saved? # frappe:unless=new
      self.status = 201
      {record: changes.record}
    end

    def render(result)
      redirect_to(@@SINGULAR@@_path(result[:record].id))
    end
  end
end
