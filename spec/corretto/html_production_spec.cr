require "spec"
require "../../src/caramel/corretto"

describe "Corretto production HTML expectations" do
  it "reads optional list and description end tags as separate browser nodes" do
    html = <<-HTML
      <section>
        <ul><li>Tea<li>Coffee</ul>
        <dl><dt>Price<dd>€12<dt>Stock<dd>Available</dl>
      </section>
      HTML
    html.should have_html {
      section {
        ul { li { "Tea" }; li { "Coffee" } }
        dl { dt { "Price" }; dd { "€12" }; dt { "Stock" }; dd { "Available" } }
      }
    }
    html.should have_html(within: "ul", count: 2) { li }
  end

  it "matches the tbody that browsers insert around ordinary table rows" do
    html = "<table><tr><th>Item</th><th>Quantity</th></tr><tr><td>Tea</td><td>2</td></tr></table>"
    html.should have_html(strict: true) {
      table {
        tbody {
          tr { th { "Item" }; th { "Quantity" } }
          tr { td { "Tea" }; td { "2" } }
        }
      }
    }
  end

  it "retains rows in a multi-row swap fragment preceded by formatting and a comment" do
    html = <<-HTML
      <!-- refreshed cart -->
      <tr data-id="tea"><td>Tea</td><td>2</td></tr>
      <tr data-id="coffee"><td>Coffee</td><td>1</td></tr>
      HTML
    html.should have_html(count: 2) { tr { td } }
    html.should have_html { tr(data_id: "coffee") { td { "Coffee" }; td { "1" } } }
  end

  it "retains column and grouped option swap fragments" do
    columns = "<!-- widths --><col span=2><col class=price>"
    columns.should have_html(count: 2) { col }
    options = <<-HTML
      <optgroup label="Available"><option value=tea selected>Tea<option value=coffee>Coffee
      </optgroup><optgroup label="Sold out"><option disabled>Chocolate</optgroup>
      HTML
    options.should have_html {
      optgroup(label: "Available") {
        option(value: "tea", selected: true) { "Tea" }
        option(value: "coffee", selected: false) { "Coffee" }
      }
    }
    options.should have_html { optgroup(label: "Sold out") { option(disabled: true) } }
  end

  it "uses the browser's repaired paragraph ancestry" do
    html = "<article><p>Summary<div class=details>Details</div>After</article>"
    html.should have_html { article { p { "Summary" }; div(class: "details") { "Details" } } }
    html.should_not have_html { p { div(class: "details") } }
    html.should have_html { article { plain "After" } }
  end

  it "decodes query attributes once without changing URL encoding" do
    html = <<-HTML
      <a href="/search?q=tea%20%26%20coffee&amp;page=2&amp;label=%3CNew%3E">Next</a>
      HTML
    href = "/search?q=tea%20%26%20coffee&page=2&label=%3CNew%3E"
    html.should have_html { a(href: href) { "Next" } }
    html.should_not have_html { a(href: "/search?q=tea & coffee&page=2&label=<New>") }
    "<input value='&amp;lt;New&amp;gt;'>".should have_html { input(value: "&lt;New&gt;") }
    "<input value='&amp;lt;New&amp;gt;'>".should_not have_html { input(value: "<New>") }
  end

  it "reads escaped JSON data attributes as their original literal values" do
    html = <<-HTML
      <button hx-vals='{&quot;title&quot;:&quot;&lt;Tea&gt;&quot;,&quot;qty&quot;:2}'
        data-label="Tom &amp; Jerry">Add</button>
      HTML
    values = %({"title":"<Tea>","qty":2})
    html.should have_html {
      button(hx_vals: values, data: {label: "Tom & Jerry"}) { "Add" }
    }
  end

  it "retains localized symbols and nonbreaking spaces in visible prices" do
    html = "<p>Crème brûlée — 12&#8239;345,67&nbsp;€ · 東京 🍵</p>"
    html.should have_html { p { "Crème brûlée — 12\u202f345,67\u00a0€ · 東京 🍵" } }
    html.should_not have_html { p { "Crème brûlée — 12 345,67 € · 東京 🍵" } }
  end

  it "matches nested SVG names whose parsed spelling preserves camel case" do
    html = <<-HTML
      <svg><defs><linearGradient id="shade"><stop offset="0"></stop></linearGradient></defs></svg>
      HTML
    html.should have_html {
      element("svg") {
        element("defs") { element("linearGradient", id: "shade") { element("stop", offset: 0) } }
      }
    }
    html.should_not have_html {
      element("svg") { element("linearGradient", id: "missing") }
    }
  end

  it "treats a false-looking boolean attribute as present" do
    html = "<input type=checkbox checked=checked disabled=false required=''>"
    html.should have_html { input(type: "checkbox", checked: true, disabled: true, required: true) }
    html.should_not have_html { input(disabled: false) }
    html.should_not have_html { input(checked: false) }
  end

  it "scopes hidden security and method fields to their submitted form" do
    html = <<-HTML
      <form action="/cart/tea" method=post>
        <input type=hidden name=_csrf value="token&amp;signature">
        <input type=hidden name=_method value=delete>
        <button type=submit>Remove tea</button>
      </form>
      <form action="/cart/coffee" method=post>
        <input type=hidden name=_csrf value=other>
        <button type=submit>Remove coffee</button>
      </form>
      HTML
    html.should have_html {
      form(action: "/cart/tea", method: "post") {
        input(type: "hidden", name: "_csrf", value: "token&signature")
        input(type: "hidden", name: "_method", value: "delete")
        button(type: "submit") { "Remove tea" }
      }
    }
    html.should_not have_html {
      form(action: "/cart/coffee") { input(name: "_method", value: "delete") }
    }
  end

  it "counts complete cards once when selected scopes overlap" do
    html = <<-HTML
      <main><section class=catalog>
        <article class="product available"><h2>Tea</h2><button>Add</button></article>
        <article class="product sold-out"><h2>Coffee</h2></article>
        <article class="product available"><h2>Chocolate</h2><button>Add</button></article>
      </section></main>
      HTML
    html.should have_html(within: "main, .catalog", count: 2) {
      article(class: "product available") { h2; button { "Add" } }
    }
    html.should_not have_html(within: "main, .catalog", count: 3) {
      article(class: "product") { button { "Add" } }
    }
  end

  it "requires partial swap and content in the same matching partial" do
    html = <<-HTML
      <hx-partial hx-target="#cart" hx-swap="beforeend"><li>Tea</li></hx-partial>
      <hx-partial hx-target="#cart" hx-swap="innerMorph"><li>Coffee</li></hx-partial>
      <hx-partial hx-target="#other" hx-swap="beforeend"><li>Coffee</li></hx-partial>
      HTML
    response = Caramel::Response.new(200, html)
    response.should render_partial("#cart", swap: "innerMorph") { li { "Coffee" } }
    response.should_not render_partial("#cart", swap: "beforeend") { li { "Coffee" } }
  end

  it "accepts a later matching partial without pooling its sibling requirements" do
    html = <<-HTML
      <hx-partial hx-target="#cart" hx-swap="beforeend"><li><span>Tea</span></li></hx-partial>
      <hx-partial hx-target="#cart" hx-swap="beforeend"><li><span>Coffee</span></li></hx-partial>
      HTML
    response = Caramel::Response.new(200, html)
    response.should render_partial("#cart", swap: "beforeend") { li { span { "Coffee" } } }
    response.should_not render_partial("#cart", swap: "beforeend") {
      li { span { "Tea" }; span { "Coffee" } }
    }
  end

  it "normalizes HTML source newlines before preserving textarea content" do
    html = "<textarea>\r\nFirst line\r\n  Second line</textarea>"
    html.should have_html { textarea { "First line\n  Second line" } }
    html.should_not have_html { textarea { "First line Second line" } }
  end

  it "keeps ordinary template content outside the document's visible row count" do
    html = <<-HTML
      <main>
        <table><tr><td>Tea</td></tr></table>
        <template id="new-row"><tr><td>Coffee</td></tr></template>
      </main>
      HTML
    html.should have_html(count: 1) { tr }
    html.should have_html { template(id: "new-row") }
    html.should_not have_html { tr { td { "Coffee" } } }
  end

  it "reads plain content across nonrendered cache comments" do
    html = "<p>Subtotal<!-- cached amount -->: €12</p>"
    html.should have_html { p { plain "Subtotal: €12" } }
    html.should have_html(strict: true) { p { plain "Subtotal: €12" } }
  end

  it "matches strict mixed content consistently across pretty and minified markup" do
    pretty = <<-HTML
      <p>
        Price: <strong>€12</strong> today
      </p>
      HTML
    minified = "<p>Price: <strong>€12</strong> today</p>"
    [pretty, minified].each do |html|
      html.should have_html(strict: true) {
        p { plain "Price: "; strong { "€12" }; plain " today" }
      }
    end
  end
end
