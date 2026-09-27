module App
  abstract struct ApplicationAction < Caramel::Action
    include App::Paths

    def layout(page : Caramel::Page) : String
      view("layouts/application", title: page.title, body: Caramel::HTML::Safe.new(page.body))
    end

    def title_for(page : Caramel::Page) : String
      "#{page.title} · #{App::TITLE}"
    end
  end
end
