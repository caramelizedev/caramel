require "spec"
require "../../src/caramel/corretto"

describe "Corretto HTML expectations" do
  it "records nested requirements without rendering the expected values" do
    title = "<Dune>"
    html = <<-HTML
      <section data-other="yes" class="wide form-page">
        <header><h1>Book</h1></header>
        <dl><dt>Title</dt><dd>&lt;Dune&gt;</dd></dl>
        <a title="Edit" href='/books/7/edit'>Edit book</a>
      </section>
      HTML
    html.should have_html {
      section(class: "form-page") {
        h1 { "Book" }
        dl { dd { title } }
        a(href: "/books/7/edit") { "Edit book" }
      }
    }
  end

  it "compares decoded attributes, boolean presence, and class tokens" do
    html = %(<input class="wide field" disabled value="&lt;a&amp;b&gt;" data-book-id="7">)
    html.should have_html {
      input(class: ["field"], disabled: true, checked: false,
        value: "<a&b>", data: {book_id: 7})
    }
    html.should_not have_html { input(disabled: false) }
    html.should_not have_html { input(class: "fie") }
    "<p class='a&nbsp;b'>".should_not have_html { p(class: "a") }
  end

  it "normalizes HTML whitespace and preserves preformatted text" do
    "<h1> Hello\n <em>world</em> </h1>".should have_html { h1 { "Hello world" } }
    "<pre> a\n b </pre>".should have_html { pre { " a\n b " } }
    "<pre> a\n b </pre>".should_not have_html { pre { "a b" } }
    "<textarea> a\n b </textarea>".should_not have_html { textarea { "a b" } }
    "<pre><code> a\n b </code></pre>".should_not have_html { code { "a b" } }
    "<p>a&nbsp;b</p>".should_not have_html { p { "a b" } }
  end

  it "matches plain text beside child elements" do
    html = "<li><code>seats</code>: must be at least 1</li>"
    html.should have_html {
      li {
        code { "seats" }
        plain ": must be at least 1"
      }
    }
    html.should_not have_html { li { plain "seats" } }
  end

  it "does not combine requirements across unrelated parents" do
    html = "<article><h1>Dune</h1></article><article><a>Edit</a></article>"
    html.should_not have_html { article { h1 { "Dune" }; a { "Edit" } } }
  end

  it "uses distinct sibling nodes and handles overlapping requirements" do
    "<ul><li>A</li></ul>".should_not have_html { ul { li; li } }
    "<ul><li>A</li><li>B</li></ul>".should have_html { ul { li; li { "A" } } }
    "<ul><li>A</li><li>B</li></ul>".should have_html {
      ul { ["B", "A"].each { |value| li { value } } }
    }
  end

  it "supports scopes, counts, and negative assertions" do
    html = "<main><p>A</p><p>B</p></main><footer><p>C</p></footer>"
    html.should have_html(within: "main", count: 2) { p }
    html.should_not have_html(within: "main") { p { "C" } }
    html.should have_html(count: 0) { article }
    html.should_not have_html(count: 3) { p { "A" } }
    expect_raises(ArgumentError, "nonnegative") { have_html(count: -1) { p } }
  end

  it "rejects many repeated requirements without enumerating permutations" do
    html = "<ul>#{"<li>A</li>" * 20}</ul>"
    html.should_not have_html { ul { 21.times { li { "A" } } } }
  end

  it "refuses invalid or missing scopes even for negative assertions" do
    expect_raises(ArgumentError, "Cannot inspect HTML") do
      "<p>A</p>".should_not have_html(within: "[") { p }
    end
    expect_raises(ArgumentError, "matched no elements") do
      "<p>A</p>".should_not have_html(within: "#absent") { p }
    end
    expect_raises(ArgumentError, "one root") { have_html { } }
    expect_raises(ArgumentError, "one root") { have_html { h1; h2 } }
  end

  it "requires direct ordered structure and all attributes in strict mode" do
    html = "<ul class='b a'>\n<li>A</li><!-- comment --><li>B</li>\n</ul>"
    html.should have_html(strict: true) { ul(class: "a b") { li { "A" }; li { "B" } } }
    html.should_not have_html(strict: true) { ul(class: "a b") { li { "B" }; li { "A" } } }
    html.should_not have_html(strict: true) { ul { li { "A" }; li { "B" } } }
    html.should_not have_html(strict: true) { ul(class: "a b") { li { "A" } } }
    "<div><section><h1>A</h1></section></div>".should_not have_html(strict: true) {
      div { h1 { "A" } }
    }
    "<h1><b>A</b></h1>".should_not have_html(strict: true) { h1 { "A" } }
    "<p>A<!-- ignored -->B</p>".should have_html(strict: true) { p { "AB" } }
    "<p>AB</p>".should have_html(strict: true) { p { plain "A"; plain "B" } }
  end

  it "parses table and select fragments without dropping their elements" do
    "<tr><td>Dune</td></tr>".should have_html { tr { td { "Dune" } } }
    "<td>Dune</td>".should have_html { td { "Dune" } }
    "<tbody><tr><td>Dune</td></tr></tbody>".should have_html { tbody { tr { td } } }
    "<option value='7' selected>Dune</option>".should have_html {
      option(value: 7, selected: true) { "Dune" }
    }
    "<select><option>Dune</option></select>".should have_html { select_tag { option } }
    "<book-card data-id='7'>Dune</book-card>".should have_html {
      element("book-card", data_id: 7) { "Dune" }
    }
  end

  it "fails when escaped input is mutated into markup" do
    escaped = "<p>&lt;b&gt;Milk&lt;/b&gt;</p>"
    injected = "<p><b>Milk</b></p>"
    escaped.should have_html { p { "<b>Milk</b>" } }
    injected.should_not have_html { p { "<b>Milk</b>" } }
    escaped.should_not have_html { b }
    expect_raises(Spec::AssertionFailed, "expected text") do
      injected.should have_html { p { "<b>Milk</b>" } }
    end
    input = "<img src=x onerror=alert(1)>"
    "<p>#{Caramel::HTML.escape(input)}</p>".should have_html { p { input } }
    expect_raises(Spec::AssertionFailed) do
      "<p>#{input}</p>".should have_html { p { input } }
    end
  end

  it "reads partial attributes independently of serialization and scopes their contents" do
    html = <<-HTML
      <hx-partial hx-swap='beforeend' data-extra='yes' hx-target='#notes'>
        <li>&lt;b&gt;Milk&lt;/b&gt; ×2</li>
      </hx-partial>
      <hx-partial hx-target="#other" hx-swap="innerMorph"><li>Elsewhere</li></hx-partial>
      HTML
    response = Caramel::Response.new(200, html)
    response.should render_partial("#notes", swap: "beforeend") { li { "<b>Milk</b> ×2" } }
    response.should_not render_partial("#notes") { li { "Elsewhere" } }
    response.should_not render_partial("#other", swap: "beforeend")
    padded = Caramel::Response.new(200, "<p>#{"x" * 1000}</p>#{html}")
    error = expect_raises(Spec::AssertionFailed) do
      padded.should render_partial("#notes") { li { "Missing" } }
    end
    error.message.to_s.should contain("HTML: <hx-partial")
  end

  it "distinguishes a document from a title-bearing fragment" do
    full = Caramel::Response.new(200,
      "<!doctype html><html><head><title data-test='yes'>Tom &amp; Jerry</title></head></html>")
    full.should render_page("Tom & Jerry")
    fragment = Caramel::Response.new(200, "<title>Tom &amp; Jerry</title><p>Hello</p>")
    fragment.should_not render_page("Tom")
    fragment.should have_html { title { "Tom & Jerry" } }
    fake = Caramel::Response.new(200, "<!-- <!doctype html> --><title>Tom</title>")
    fake.should_not render_page("Tom")
  end

  it "shows the expectation path, observed value, and relevant bounded excerpt" do
    html = "<article><h1>Wrong</h1></article>"
    error = expect_raises(Spec::AssertionFailed) do
      html.should have_html { article { h1 { "Dune" } } }
    end
    error.message.to_s.should contain("article > h1")
    error.message.to_s.should contain("Wrong")
    error.message.to_s.should contain("found 0")
    absent = expect_raises(Spec::AssertionFailed) do
      "<article><a>Edit</a></article>".should have_html { article { h1 { "Dune" } } }
    end
    absent.message.to_s.should contain("article > h1: no matching node")
    expect_raises(Spec::AssertionFailed, "Expected not") do
      html.should_not have_html { article }
    end
    error = expect_raises(Spec::AssertionFailed) do
      html.should have_html(count: 2) { article }
    end
    error.message.to_s.should contain("found 1")
    error.message.to_s.should contain("Expected exactly 2 matching roots")
    large = "<p>#{"x" * 4000}</p>"
    error = expect_raises(Spec::AssertionFailed) { large.should have_html { p { "small" } } }
    error.message.to_s.size.should be < 1800
  end
end
