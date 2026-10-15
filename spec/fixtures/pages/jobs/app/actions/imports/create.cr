module App::Imports
  struct Create < App::ApplicationAction
    contract do
      field title : String
      field author : String
    end

    def handle(contract : Contract)
      id = SugarORM::Repo.transaction do
        App::ImportBook.enqueue(title: contract.title, author: contract.author)
      end
      morph("#imports", with: "Import #{id} queued", status: 202)
    end
  end
end
