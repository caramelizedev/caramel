module App
  struct ImportBook < Caramel::ColdBrew::Job
    queue "imports"
    param title : String
    param author : String

    def perform
      App::Book.create!(title: title, author: author)
    end
  end
end
