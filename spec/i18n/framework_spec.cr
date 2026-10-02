require "spec"
require "./support/app"

private def draft_errors(locale : Caramel::Locale) : Array(String)
  Caramel::I18n.with(locale) do
    I18nSpec::Note::DraftChangeset.new(title: " ").errors["title"]
  end
end

describe "Caramel's own messages" do
  it "renders a contract failure page in the request's locale" do
    page = I18nSpec.post("/fr/notes", "title=ab", HTTP::Headers{"Accept" => "text/html"})
    page.should have_status(422)
    page.should render_page("Vérifiez votre requête")
    page.should have_html {
      li {
        code { "title" }
        plain ": doit compter au moins 3 caractères"
      }
    }
  end

  it "keeps the JSON shape, with the locale's messages" do
    json = HTTP::Headers{"Accept" => "application/json"}
    response = I18nSpec.post("/fr/notes", "title=ab", json)
    response.body.should eq(%({"errors":{"title":["doit compter au moins 3 caractères"]}}))
  end

  it "answers a path no route matches in the request's locale" do
    missing = I18nSpec.get("/fr/missing")
    missing.should have_status(404)
    missing.body.should eq("Page introuvable")
    I18nSpec.get("/missing").body.should eq("Not found")
  end

  it "translates changeset errors made in a locale" do
    expected = ["ne peut pas être vide", "doit compter au moins 3 caractère(s)"]
    draft_errors(Caramel::Locale::Fr).should eq(expected)
  end

  it "keeps English where neither the locale nor the default locale translates" do
    expected = ["can't be blank", "should be at least 3 character(s)"]
    draft_errors(Caramel::Locale::Ru).should eq(expected)
  end
end
