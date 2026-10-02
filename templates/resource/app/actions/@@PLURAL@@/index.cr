module App::@@COLLECTION@@
  struct Index < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      {records: App::@@MODEL@@.query.order_by(:id, :desc).limit(100).to_a}
    end

    def render(result)
      # frappe:only locales
      page t.@@PLURAL@@.collection, Views::@@COLLECTION@@::Index.new(result[:records])
      # frappe:else
      page "@@COLLECTION_LABEL@@", Views::@@COLLECTION@@::Index.new(result[:records])
      # frappe:end
    end
  end
end
