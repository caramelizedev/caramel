require "spec"
require "./support/app"

private alias Locale = Caramel::Locale

private def t(locale : Locale) : Caramel::Messages
  I18nSpec.t(locale)
end

describe "Caramel::Messages" do
  it "returns each locale's own text" do
    t(Locale::En).home.title.should eq("Welcome")
    t(Locale::Fr).home.title.should eq("Bienvenue")
  end

  it "falls back to the default locale's text for a key a locale lacks" do
    t(Locale::Fr).home.farewell.should eq("Goodbye")
    t(Locale::Ru).home.title.should eq("Welcome")
  end

  it "accepts finalize as a placeholder name, though not as a key" do
    t(Locale::En).home.closing(finalize: "Ann").should eq("Closed by Ann")
  end

  it "escapes a placeholder's text where a page writes it" do
    page = I18nSpec.get("/")
    page.body.should contain("<span>Hello, &lt;Ann&gt;!</span>")
    page.should have_html { span { "Hello, <Ann>!" } }
  end

  it "writes a safe argument as it is and escapes the text around it" do
    link = Caramel::HTML::Safe.new(%(<a href="/aide">l'aide</a>))
    help = t(Locale::Fr).home.help(link: link)
    help.should be_a(Caramel::HTML::Safe)
    help.to_s.should eq(%(Lisez d&#39;abord <a href="/aide">l'aide</a>.))
  end

  it "answers an exact count before the plural rules" do
    t(Locale::En).books.count(0).should eq("No books")
    t(Locale::Fr).books.count(0).should eq("Aucun livre")
  end

  it "chooses English's forms by count" do
    t(Locale::En).books.count(1).should eq("1 book")
    t(Locale::En).books.count(2).should eq("2 books")
  end

  it "chooses Russian's one, few and many forms by the count's ending" do
    expected = {
      1 => "1 книга", 2 => "2 книги", 5 => "5 книг",
      11 => "11 книг", 21 => "21 книга", 22 => "22 книги",
    }
    expected.each { |count, text| t(Locale::Ru).books.count(count).should eq(text) }
  end

  it "chooses each of Arabic's six forms" do
    expected = {
      0 => "لا كتب", 1 => "كتاب واحد", 2 => "كتابان",
      3 => "3 كتب", 11 => "11 كتابًا", 100 => "100 كتاب",
    }
    expected.each { |count, text| t(Locale::Ar).books.count(count).should eq(text) }
  end

  it "writes the count with the locale's delimiter" do
    t(Locale::Fr).books.count(1000).should eq("1 000 livres")
    t(Locale::En).books.count(1000).should eq("1,000 books")
  end
end
