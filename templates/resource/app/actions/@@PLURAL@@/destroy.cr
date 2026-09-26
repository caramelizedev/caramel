module App::@@COLLECTION@@
  class Destroy < App::ApplicationAction
    contract do
      field id : Int64, min: 1
    end

    struct Result
      include JSON::Serializable
      getter id : Int64

      def initialize(@id)
      end
    end

    def handle(contract : Contract) : Result | Caramel::Response
      record = App::@@MODEL@@.find(contract.id)
      return Caramel::Response.new(404, "@@MODEL@@ not found") unless record && record.delete
      Result.new(contract.id)
    end

    def respond_html(result : Result) : Caramel::Response
      redirect_to(@@PLURAL@@_path)
    end
  end
end
