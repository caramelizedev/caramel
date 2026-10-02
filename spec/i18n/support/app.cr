require "../../../src/caramel/corretto"
require "../../../src/caramel/i18n"

Caramel.locale "en", {
  home: {
    title:    "Welcome",
    greeting: "Hello, %{name}!",
    help:     "Read %{link} first.",
    farewell: "Goodbye",
  },
  books: {
    count: {"=0": "No books", one: "%{count} book", other: "%{count} books"},
  },
}

Caramel.locale "fr", {
  caramel: {
    language: "Français",
    number:   {separator: ",", delimiter: " "},
    time:     {
      months: %w[
        janvier février mars avril mai juin
        juillet août septembre octobre novembre décembre
      ],
      formats: {date: "%-d %B %Y", time: "%H:%M"},
    },
    errors: {
      at_least_characters: "doit compter au moins %{min} caractères",
      blank:               "ne peut pas être vide",
      too_short:           "doit compter au moins %{min} caractère(s)",
    },
    pages: {check_request: "Vérifiez votre requête", not_found: "Page introuvable"},
  },
  home: {
    title:    "Bienvenue",
    greeting: "Bonjour, %{name} !",
    help:     "Lisez d'abord %{link}.",
  },
  books: {
    count: {
      "=0":  "Aucun livre",
      one:   "%{count} livre",
      many:  "%{count} de livres",
      other: "%{count} livres",
    },
  },
}

Caramel.locale "ru", {
  books: {
    count: {one: "%{count} книга", few: "%{count} книги", many: "%{count} книг"},
  },
}

Caramel.locale "ar", {
  books: {
    count: {
      zero:  "لا كتب",
      one:   "كتاب واحد",
      two:   "كتابان",
      few:   "%{count} كتب",
      many:  "%{count} كتابًا",
      other: "%{count} كتاب",
    },
  },
}

Caramel.locales default: "en", prefix: true

module I18nSpec
  struct Note < SugarORM::Schema
    schema "i18n_spec_notes" do
      field id : Int64, primary: true
      field title : String
    end
  end

  class Note::DraftChangeset < SugarORM::Changeset(Note)
    param title : String

    def validate(cs)
      cs.validate_presence(:title)
      cs.validate_length(:title, min: 3)
    end
  end

  abstract struct Action < Caramel::Action
    Caramel.resource_paths :books, :book
  end

  struct Home < Action
    contract do
    end

    def handle(contract : Contract)
      page t.home.title, markup { span { t.home.greeting(name: "<Ann>") } }
    end
  end

  struct CreateNote < Action
    contract do
      field title : String, min: 3
    end

    def handle(contract : Contract)
      redirect_to("/")
    end
  end

  struct Books < Action
    contract do
    end

    def handle(contract : Contract)
      Caramel::Response.new(200, books_path)
    end
  end

  struct Stream < Action
    contract do
    end

    def handle(contract : Contract)
      stream("text/plain; charset=utf-8") { |io| io << t.home.title }
    end
  end

  Caramel::Router.draw do
    get "/", Home
    post "/notes", CreateNote
    get "/books", Books
    get "/stream", Stream
  end

  ORIGIN = "https://i18n.caramel"
  CSRF   = Caramel::CSRF.new("s" * 64, ORIGIN)
  APP    = Caramel::Application.new(AppRouter.new, CSRF)

  # The messages *locale* holds, as `t` returns them in a request.
  def self.t(locale : Caramel::Locale) : Caramel::Messages
    Caramel::Messages.new(locale)
  end

  def self.get(path : String, headers = HTTP::Headers.new) : Caramel::Response
    headers["Host"] = "i18n.caramel"
    APP.handle(HTTP::Request.new("GET", path, headers))
  end

  # A CSRF-protected form post of *body* to *path*.
  def self.post(path : String,
                body : String,
                headers = HTTP::Headers.new) : Caramel::Response
    token = CSRF.issue
    headers["Host"] = "i18n.caramel"
    headers["Origin"] = ORIGIN
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Cookie"] = "#{Caramel::CSRF::COOKIE_NAME}=#{token}"
    APP.handle(HTTP::Request.new("POST", path, headers, "_csrf=#{token}&#{body}"))
  end

  # What the server writes for a GET of *path*, streamed bodies included.
  def self.served(path : String, headers = HTTP::Headers.new) : String
    headers["Host"] = "i18n.caramel"
    output = IO::Memory.new
    response = HTTP::Server::Response.new(output)
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", path, headers), response)
    APP.call(context)
    response.close
    output.to_s
  end

  # Formats with `l` the way a view or action does, in *locale*.
  struct Localizer
    include Caramel::Localized
  end

  def self.l(locale : Caramel::Locale, number : Float64, decimals : Int32) : String
    Caramel::I18n.with(locale) { Localizer.new.l(number, decimals) }
  end

  def self.l(locale : Caramel::Locale,
             time : Time,
             format : Caramel::I18n::TimeFormat) : String
    Caramel::I18n.with(locale) { Localizer.new.l(time, format) }
  end
end
