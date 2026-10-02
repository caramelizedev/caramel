# plain.cr with caramel/i18n and two locales; scripts/checks/i18n.cr builds
# both and compares their binaries.
require "../../../src/caramel"
require "../../../src/caramel/i18n"

Caramel.locale "en", {
  home: {title: "Home"},
}

Caramel.locale "fr", {
  home: {title: "Accueil"},
}

Caramel.locales default: "en", prefix: false

module I18nZeroCost
  struct Home < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page t.home.title, "<p>#{t.home.title}</p>"
    end
  end

  Caramel::Router.draw do
    get "/", Home
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://zero.caramel")
app = Caramel::Application.new(I18nZeroCost::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "zero.caramel", "Accept-Language" => "fr"}
{"/", "/fr"}.each do |path|
  response = app.handle(HTTP::Request.new("GET", path, headers))
  puts "#{response.status} #{response.headers["Content-Language"]? || "-"}"
end
