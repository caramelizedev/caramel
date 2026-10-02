require "../../../src/caramel/i18n"

Caramel.locale "en", {
  caramel: {
    time: {formats: {long: "%A, %B %-d, %Y at %-I:%M %p"}},
  },
  home: {
    title:    "Welcome",
    greeting: "Hello, %{name}!",
  },
  books: {
    count:  {"=0": "No books", one: "%{count} book", other: "%{count} books"},
    shelf:  {one: "%{count} book on %{shelf}", other: "%{count} books on %{shelf}"},
    fields: {title: "Title"},
  },
}

Caramel.locale "pt-BR", {
  caramel: {
    language: "Português",
    number:   {separator: ",", delimiter: "."},
    errors:   {required: "é obrigatório", at_least: "deve ser pelo menos %{min}"},
    pages:    {not_found: "Não encontrado"},
  },
  home:  {title: "Bem-vindo"},
  books: {
    count: {one: "%{count} livro", many: "%{count} de livros", other: "%{count} livros"},
  },
}

Caramel.locale "zh-Hant", {
  books: {count: {other: "%{count} 本書"}},
}

Caramel.locale "eo", {
  home: {title: "Bonvenon"},
}, plural: "en"

Caramel.locales default: "en", prefix: true

module Fixture
  class Shelf < Caramel::View
    def initialize(@count : Int32)
    end

    private def blueprint
      h1 { t.home.title }
      p { t.books.count(@count) }
      p { t.books.shelf(@count, shelf: "B2") }
      p { t.home.greeting(name: markup { strong { "Ann" } }) }
      p { l(Time.utc, :long) }
      a(href: switch_locale_path(Caramel::Locale::PtBr), hx_boost: "false") { "pt-BR" }
    end
  end

  struct Index < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      page t.books.fields.title, Shelf.new(3)
    end
  end

  Caramel::Router.draw do
    get "/", Index
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://fixture.caramel")
app = Caramel::Application.new(Fixture::AppRouter.new, csrf)
headers = HTTP::Headers{"Host" => "fixture.caramel", "Accept-Language" => "pt-PT"}
puts app.handle(HTTP::Request.new("GET", "/", headers)).body
puts Caramel::Locale::ZhHant.plural(2), Caramel::Locale.parse?("PT-br")
puts Caramel::I18n.negotiate("pt"), Caramel::I18n::MISSING.size
