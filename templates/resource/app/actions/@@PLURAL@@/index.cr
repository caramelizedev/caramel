module App::@@COLLECTION@@
  class Index < App::ApplicationAction
    contract do
    end

    struct Result
      include JSON::Serializable
      getter records : Array(App::@@MODEL@@)

      def initialize(@records)
      end
    end

    def handle(contract : Contract) : Result | Caramel::Response
      Result.new(App::@@MODEL@@.order(id: :desc).limit(100).to_a)
    end

    def render(result : Result) : Caramel::Page
      records = result.records
      content = Caramel::View.render "#{__DIR__}/../../views/@@PLURAL@@/index.html.ecr"
      Caramel::Page.new("@@COLLECTION_LABEL@@", content)
    end
  end
end
