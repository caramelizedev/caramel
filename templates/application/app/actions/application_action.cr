module App
  abstract class ApplicationAction < Caramel::Action
    include App::Paths

    def layout(page : Caramel::Page) : String
      title = page.title
      body = Caramel::HTML::Safe.new(page.body)
      Caramel::View.render "#{__DIR__}/../views/layouts/application.html.ecr"
    end

    def title_for(page : Caramel::Page) : String
      "#{page.title} · #{App::TITLE}"
    end
  end
end
