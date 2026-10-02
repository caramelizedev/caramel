require "spec"
require "./support/app"

private def accepting(languages : String) : HTTP::Headers
  HTTP::Headers{"Accept-Language" => languages}
end

private def remembering(code : String) : HTTP::Headers
  HTTP::Headers{"Cookie" => "#{Caramel::I18n::COOKIE_NAME}=#{code}"}
end

describe "Caramel locale resolution" do
  it "serves the best Accept-Language match and names it" do
    page = I18nSpec.get("/", accepting("fr-CA,fr;q=0.9,en;q=0.5"))
    page.body.should contain(%(<html lang="fr">))
    page.headers["Content-Language"].should eq("fr")
  end

  it "ignores a language weighted zero" do
    I18nSpec.get("/", accepting("fr;q=0")).headers["Content-Language"].should eq("en")
  end

  it "ignores an Accept-Language longer than 1024 bytes" do
    long = "fr," + "x" * 1100
    I18nSpec.get("/", accepting(long)).headers["Content-Language"].should eq("en")
  end

  it "prefers the remembered locale to Accept-Language" do
    headers = remembering("ru").merge!(accepting("fr"))
    I18nSpec.get("/", headers).headers["Content-Language"].should eq("ru")
  end

  it "says that a negotiated response varies by Accept-Language and Cookie" do
    vary = I18nSpec.get("/books", accepting("fr")).headers.get("Vary")
    vary.should contain("Accept-Language, Cookie")
  end

  it "serves a prefixed path in its locale, with prefixed links and no Vary" do
    books = I18nSpec.get("/fr/books", accepting("ru"))
    books.body.should eq("/fr/books")
    books.headers["Content-Language"].should eq("fr")
    books.headers.has_key?("Vary").should be_false
  end

  it "remembers the locale a prefix names" do
    cookie = I18nSpec.get("/fr/books").headers["Set-Cookie"]
    cookie.should start_with("#{Caramel::I18n::COOKIE_NAME}=fr;")
  end

  it "gives the default locale no prefix" do
    I18nSpec.get("/en/books").status.should eq(404)
  end

  it "switches locale with ?locale=, remembering it" do
    switched = I18nSpec.get("/books?locale=fr&page=2")
    switched.should have_status(303)
    switched.should redirect_to("/fr/books?page=2")
    cookie = switched.headers["Set-Cookie"]
    cookie.should start_with("#{Caramel::I18n::COOKIE_NAME}=fr;")
    cookie.downcase.should contain("httponly")
  end

  it "switches an htmx request with HX-Redirect" do
    switched = I18nSpec.get("/books?locale=fr", HTTP::Headers{"HX-Request" => "true"})
    switched.should have_status(200)
    switched.should have_header("HX-Redirect", "/fr/books")
  end

  it "ignores a ?locale= that names no locale" do
    response = I18nSpec.get("/books?locale=xx", accepting("fr"))
    response.should have_status(200)
    response.headers["Content-Language"].should eq("fr")
  end

  it "streams a body in the request's locale" do
    I18nSpec.served("/stream", accepting("fr")).should contain("Bienvenue")
  end
end
