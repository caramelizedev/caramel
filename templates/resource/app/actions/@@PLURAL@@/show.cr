module App::@@COLLECTION@@
  class Show < App::ApplicationAction
    contract do
      field id : Int64, min: 1
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
      Result.new(record)
    end

    def render(result : Result) : Caramel::Page
      record = result.record
      content = Caramel::View.render "#{__DIR__}/../../views/@@PLURAL@@/show.html.ecr"
      Caramel::Page.new("@@MODEL@@", content)
    end
  end
end
