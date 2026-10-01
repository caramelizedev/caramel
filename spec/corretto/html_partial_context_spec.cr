require "spec"
require "../../src/caramel/corretto"

private def partial_response(target, content)
  partial = Caramel::Partial.new(target, content, "beforeend")
  Caramel::Response.new(200, Caramel::Hypermedia.render([partial]))
end

describe "Corretto partial fragment contexts" do
  it "keeps table rows in the same protocol envelope that supplied their target" do
    response = partial_response("#books", "<tr id='book-7'><td>Dune</td><td>2</td></tr>")
    response.should render_partial("#books", swap: "beforeend") {
      tr(id: "book-7") { td { "Dune" }; td { 2 } }
    }
    response.should have_html(within: "hx-partial", count: 1, strict: true) {
      tr(id: "book-7") { td { "Dune" }; td { 2 } }
    }
    response.should_not have_html { table }
  end

  it "keeps cells, table sections and columns without synthetic wrappers" do
    partial_response("#row", "<td>Dune</td><td>2</td>").should render_partial("#row") {
      td { "Dune" }
    }
    partial_response("#table", "<tbody><tr><td>Dune</td></tr></tbody>")
      .should render_partial("#table") { tbody { tr { td { "Dune" } } } }
    partial_response("#columns", "<col span='2'>").should render_partial("#columns") {
      col(span: 2)
    }
  end

  it "preserves a title and comments before context-sensitive content" do
    content = <<-HTML
      <!-- a fragment may update the page title as well as its rows -->
      <title>Book &amp; Tea</title>
      <tr><td>&lt;Dune&gt;</td></tr>
      HTML
    response = partial_response("#books", content)
    response.should render_partial("#books") { tr { td { "<Dune>" } } }
    response.should have_html(within: "hx-partial") { title { "Book & Tea" } }
  end

  it "uses byte offsets when Unicode text precedes an envelope" do
    source = %(<p>🚲 café · 東京</p><hx-partial hx-target="#rows"><tr><td>Tea</td></tr></hx-partial>)
    response = Caramel::Response.new(200, source)
    response.should have_html { p { "🚲 café · 東京" } }
    response.should render_partial("#rows") { tr { td { "Tea" } } }
  end

  it "keeps optional option endings and optgroups inside their own partial" do
    content = "<optgroup label='Books'><option value=7 selected>Dune<option value=8>Solaris"
    response = partial_response("#book-select", content)
    response.should render_partial("#book-select") {
      optgroup(label: "Books") {
        option(value: 7, selected: true) { "Dune" }
        option(value: 8, selected: false) { "Solaris" }
      }
    }
  end

  it "keeps multiple targets distinct when a response mixes fragment contexts" do
    fragments = [
      Caramel::Partial.new("#books", "<tr><td>Dune</td></tr>", "beforeend"),
      Caramel::Partial.new("#choices", "<option value=8>Solaris</option>", "innerHTML"),
      Caramel::Partial.new("#books", "<tr><td>Foundation</td></tr>", "beforeend"),
    ]
    response = Caramel::Response.new(200, Caramel::Hypermedia.render(fragments))
    response.should render_partial("#choices", swap: "innerHTML") { option { "Solaris" } }
    response.should have_html(count: 2) { element("hx-partial", hx_target: "#books") { tr } }
    response.should_not render_partial("#books") { tr { td { "Solaris" } } }
    response.should_not render_partial("#books") { tr { td { "Dune" }; td { "Foundation" } } }
  end

  it "retains original envelope attributes and requires no internal marker attributes" do
    source = <<-HTML
      <HX-PARTIAL data-corretto-partial="user value" hx-target="#a&amp;b"
                  hx-swap='beforeend'><tr><td>A</td></tr></HX-PARTIAL>
      HTML
    response = Caramel::Response.new(200, source)
    response.should render_partial("#a&b", swap: "beforeend") { tr { td { "A" } } }
    response.should have_html(strict: true) {
      element("hx-partial", data_corretto_partial: "user value",
        hx_target: "#a&b", hx_swap: "beforeend") { tr { td { "A" } } }
    }
  end

  it "leaves envelope-looking text, comments and ordinary templates inert" do
    source = <<-HTML
      <!-- <hx-partial hx-target="#fake"><tr><td>Fake</td></tr></hx-partial> -->
      <textarea><hx-partial hx-target="#textarea">Literal</hx-partial></textarea>
      <script>const sample = '<hx-partial hx-target="#script">Literal</hx-partial>';</script>
      <template><hx-partial hx-target="#template"><tr><td>Hidden</td></tr></hx-partial></template>
      <hx-partial hx-target="#real"><tr><td>Visible</td></tr></hx-partial>
      <p>hx-partial</p>
      HTML
    response = Caramel::Response.new(200, source)
    response.should render_partial("#real") { tr { td { "Visible" } } }
    response.should_not render_partial("#fake")
    response.should_not render_partial("#textarea")
    response.should_not render_partial("#script")
    response.should_not render_partial("#template")
    response.should have_html(count: 1) { tr }
    literal = %(<hx-partial hx-target="#textarea">Literal</hx-partial>)
    response.should have_html { textarea { literal } }
    response.should have_html { p { "hx-partial" } }
  end

  it "keeps table partials in full page responses and reports their relevant content" do
    source = <<-HTML
      <!doctype html><html><head><title>Books</title></head><body>
      <hx-partial hx-target="#books"><tr id="book-7"><td>Dune</td></tr></hx-partial>
      </body></html>
      HTML
    response = Caramel::Response.new(200, source)
    response.should render_page("Books")
    response.should render_partial("#books") { tr(id: "book-7") { td { "Dune" } } }
    error = expect_raises(Spec::AssertionFailed) do
      response.should render_partial("#books") { tr { td { "Solaris" } } }
    end
    error.message.to_s.should contain("tr > td")
    error.message.to_s.should contain("<hx-partial")
    error.message.to_s.should contain("Dune")
    error.message.to_s.should_not contain("data-corretto-partial")
  end

  it "rejects protocol envelopes in foreign namespaces before inspecting native content" do
    source = %(<svg><hx-partial hx-target="#icon"><circle></circle></hx-partial></svg>)
    response = Caramel::Response.new(200, source)
    expect_raises(ArgumentError, "requires the HTML namespace") do
      response.should_not render_partial("#icon")
    end
    embedded = <<-HTML
      <svg><foreignObject>
      <hx-partial hx-target="#label"><p>Visible</p></hx-partial>
      </foreignObject></svg>
      HTML
    Caramel::Response.new(200, embedded).should render_partial("#label") { p { "Visible" } }
  end
end
