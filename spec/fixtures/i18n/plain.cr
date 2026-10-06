# An application without caramel/i18n; scripts/checks/i18n.cr builds it and
# checks that its binary holds none of the i18n code.
require "../../../src/caramel"

module I18nZeroCost
  struct Home < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  Caramel::Router.draw do
    get "/", Home
  end
end

# The canonical request lines would share stdout with the answers.
Log.setup(:none)
csrf = Caramel::CSRF.new("s" * 64, "https://zero.caramel")
app = Caramel::Application.new(I18nZeroCost::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "zero.caramel", "Accept-Language" => "fr"}
{"/", "/fr"}.each do |path|
  response = app.handle(HTTP::Request.new("GET", path, headers))
  puts "#{response.status} #{response.headers["Content-Language"]? || "-"}"
end
