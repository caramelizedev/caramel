module App::@@COLLECTION@@
  class Update < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
@@CONTRACT_FIELDS@@
    end

    struct Result
      include JSON::Serializable
      getter record : App::@@MODEL@@

      def initialize(@record)
      end
    end

    def handle(contract : Contract) : Result | Caramel::Response
      record = App::@@MODEL@@.find(contract.id)
      return Caramel::Response.new(404, "@@MODEL@@ not found") unless record
@@ASSIGNMENTS@@
      return render_form(contract.values, record.errors, contract.id, 422) unless record.save
      Result.new(record)
    end

    def respond_html(result : Result) : Caramel::Response
      redirect_to(@@SINGULAR@@_path(result.record.id.not_nil!))
    end
  end
end
