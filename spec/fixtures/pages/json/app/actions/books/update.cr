module App::Books
  struct Update < App::ApplicationAction
    include Form

    contract do
      field id : Int64, min: 1
      field title : String
      field author : String
    end

    def handle(contract : Contract)
      record = App::Book.query.find(contract.id)
      return not_found("Book not found") unless record
      unless if_match?(record.lock_version)
        return render_errors({"_base" => [SugarORM::Wording.record_stale]}, 412)
      end
      changes = record.update(title: contract.title, author: contract.author)
      return render_form(contract.values, changes.errors, contract.id, 422) unless changes.saved?
      self.etag = changes.record.lock_version
      {record: changes.record}
    end

    def render(result)
      redirect_to(book_path(result[:record].id))
    end
  end
end
