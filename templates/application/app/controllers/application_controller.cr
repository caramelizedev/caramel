module App
  abstract class ApplicationController < Caramel::Controller
    include App::Paths

    private def page(content : String, title : String, status = 200) : Caramel::Response
      body = Caramel::HTML::Safe.new(content)
      full = Caramel::View.render "#{__DIR__}/../views/layouts/application.html.ecr"
      partial = "<title>#{Caramel::HTML.escape(title)} · #{Caramel::HTML.escape(App::TITLE)}</title>#{content}"
      html(full, partial, status)
    end
  end
end
