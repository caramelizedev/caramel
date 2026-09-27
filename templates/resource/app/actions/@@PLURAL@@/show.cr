module App::@@COLLECTION@@
  struct Show < App::ApplicationAction
    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
      {record: record}
    end

    def render(result)
      page "@@MODEL@@", view("@@PLURAL@@/show", record: result[:record])
    end
  end
end
