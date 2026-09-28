module App::Views::Layouts
  class Application < App::ApplicationView
    def initialize(@page : Caramel::Page, @csrf_token : String)
    end

    private def blueprint
      doctype
      html lang: "en" do
        head do
          meta charset: "utf-8"
          meta name: "viewport", content: "width=device-width, initial-scale=1"
          title { "#{@page.title} · #{App::TITLE}" }
          link rel: "stylesheet", href: "/assets/app.css"
          script src: "/assets/htmx-4.0.0.min.js", defer: true
          script src: "/assets/caramel-islands.js", defer: true
          script src: "/assets/app.js", defer: true
        end
        body "hx-boost:inherited": "true", "hx-target:inherited": "#content", "hx-swap:inherited": "innerMorph",
          "hx-headers:inherited": {"X-CSRF-Token" => @csrf_token}.to_json do
          header class: "site-header" do
            a href: "/", class: "brand" do
              span(class: "mark", aria_hidden: "true") { "c." }
              plain App::TITLE
            end
            span(class: "made-with") { "Made with Caramel" }
          end
          main(id: "content") { raw @page.html }
          footer { "Make something worth opening." }
        end
      end
    end
  end
end
