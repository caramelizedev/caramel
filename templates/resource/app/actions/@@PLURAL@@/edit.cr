module App::@@COLLECTION@@
  struct Edit < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::@@MODEL@@.find(contract.id)
      return not_found("@@MODEL@@ not found") unless record
      values = {@@VALUES@@}
      render_form(values, {} of String => Array(String), contract.id)
    end
  end
end
