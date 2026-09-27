module App::@@COLLECTION@@
  struct Index < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      {records: App::@@MODEL@@.query.order_by(:id, :desc).limit(100).to_a}
    end

    def render(result)
      page "@@COLLECTION_LABEL@@", view("@@PLURAL@@/index", records: result[:records])
    end
  end
end
