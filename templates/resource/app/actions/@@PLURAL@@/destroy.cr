module App::@@COLLECTION@@
  struct Destroy < App::ApplicationAction
    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.query.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record && record.delete
      {id: contract.id}
    end

    def render(result)
      redirect_to(@@PLURAL@@_path)
    end
  end
end
