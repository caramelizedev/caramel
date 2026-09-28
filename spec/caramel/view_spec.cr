require "spec"
require "../../src/caramel/view"

describe Caramel::HTML do
  it "escapes HTML syntax characters in ordinary values" do
    Caramel::HTML.escape(%q(<script>& "')).should eq("&lt;script&gt;&amp; &quot;&#39;")
  end

  it "keeps explicit safe output trusted" do
    Caramel::HTML.escape(Caramel::HTML::Safe.new("<strong>trusted</strong>")).should eq("<strong>trusted</strong>")
  end
end

describe Caramel::View do
  it "renders typed locals with escaped expressions and unchanged literals" do
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    title = %q(<Hello & goodbye>)
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    slug = %q(a"b'c)
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    items = ["one", %q(<two>)]
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    trusted = Caramel::HTML::Safe.new("<em>trusted once</em>")

    rendered = Caramel::View.render("spec/fixtures/views/example.html.ecr")

    rendered.should eq(
      "<h1>&lt;Hello &amp; goodbye&gt;</h1>\n" +
      "<a href=\"/items/a&quot;b&#39;c\" title=\"&lt;Hello &amp; goodbye&gt;\">&lt;Hello &amp; goodbye&gt;</a>\n" +
      "<ul>\n" +
      "  <li>one</li>\n" +
      "  <li>&lt;two&gt;</li>\n" +
      "</ul>\n" +
      "<p><em>trusted once</em></p>\n"
    )
  end

  it "renders an empty collection without changing surrounding literals" do
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    title = "Nothing"
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    slug = "nothing"
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    items = [] of String
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    trusted = Caramel::HTML::Safe.new("<span>ready</span>")

    Caramel::View.render("spec/fixtures/views/example.html.ecr").should eq(
      "<h1>Nothing</h1>\n" +
      "<a href=\"/items/nothing\" title=\"Nothing\">Nothing</a>\n" +
      "<ul>\n" +
      "</ul>\n" +
      "<p><span>ready</span></p>\n"
    )
  end

  it "honors ECR leading and trailing whitespace suppression" do
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    visible = true

    Caramel::View.render("spec/fixtures/views/whitespace.html.ecr").should eq("before\n  shown\nafter\n")
  end

  it "keeps a caller local named __io__ separate from the render buffer" do
    __io__ = %q(<caller>)

    Caramel::View.render("spec/fixtures/views/io_collision.html.ecr").should eq("<p>&lt;caller&gt;</p>\n")
  end

  it "keeps nested buffers separate when nested output is explicitly safe" do
    # ameba:disable Lint/UselessAssign -- read by the rendered ECR template
    inner_value = %q(<inner>)

    Caramel::View.render("spec/fixtures/views/nested_outer.html.ecr").should eq("<div><span>&lt;inner&gt;</span>\n</div>\n")
  end
end
