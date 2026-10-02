require "../action"
require "../view"
require "../application"
require "./runtime"

module Caramel
  # What views and actions translate with (ADR 0024): `t` for messages,
  # `l` for numbers and times, and the request's `locale`. Inside
  # `markup { … }` they fall through to the view or action.
  module Localized
    # The request locale's messages: `t.home.greeting(name: user.name)`.
    def t
      ::Caramel::Messages.new(locale)
    end

    # The request's locale.
    def locale
      ::Caramel::I18n.locale
    end

    # *number* with the request locale's separator and delimiter, rounded to
    # *decimals* places when given.
    def l(number : Int::Primitive | Float::Primitive, decimals : Int32? = nil) : String
      ::Caramel::I18n.number(locale, number, decimals)
    end

    # *path* under the request locale's prefix, when the application uses
    # prefixes; resource path helpers already add it.
    def localize_path(path : String) : String
      ::Caramel.localize_path(path)
    end
  end

  abstract class View
    include Localized
  end

  abstract struct Action
    include Localized
  end

  class Application
    # Resolves the request's locale: a `?locale=` switch, then a `/CODE`
    # prefix, then the remembered cookie, then Accept-Language, then the
    # default. Routing runs in that locale, and the response says which.
    private def localized(request : HTTP::Request, & : HTTP::Request -> Response) : Response
      prefixed = I18n.unprefix(request)
      if switched = I18n.switch(request)
        return switched
      end
      remembered = I18n.remembered(request)
      locale = prefixed || remembered || accepted(request) || ::Caramel::Locale.default
      response = I18n.with(locale, I18n.page(request)) { yield request }
      response.headers["Content-Language"] = locale.code
      response.headers.add("Vary", "Accept-Language, Cookie") unless prefixed
      if prefixed && prefixed != remembered
        response.headers.add("Set-Cookie", I18n.cookie(prefixed).to_set_cookie_header)
      end
      response
    end

    # Streams in the locale the response was rendered in.
    private def streaming(response : Response, &) : Nil
      code = response.headers["Content-Language"]? || ""
      I18n.with(::Caramel::Locale.parse?(code) || ::Caramel::Locale.default) { yield }
    end

    private def accepted(request : HTTP::Request)
      header = request.headers["Accept-Language"]? || return
      I18n.negotiate(header)
    end
  end
end
