module App::Books
  struct Show < App::ApplicationAction
    contract do
      field id : Int64, min: 1
    end

    def handle(contract : Contract)
      record = App::Book.query.find(contract.id)
      return not_found("Book not found") unless record
      self.etag = record.lock_version
      {record: record}
    end

    def render(result)
      page "Book", Views::Books::Show.new(result[:record], csrf_token)
    end
  end
end
