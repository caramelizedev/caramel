module App
  abstract struct ApplicationAction < Caramel::Action
    include App::Paths

    def layout(page : Caramel::Page) : String
      Views::Layouts::Application.new(page, csrf_token).to_s
    end

    def title_for(page : Caramel::Page) : String
      "#{page.title} · #{App::TITLE}"
    end
  end
end
