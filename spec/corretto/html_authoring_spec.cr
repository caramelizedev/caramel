require "spec"
require "../../src/caramel/corretto"

describe "Authoring Corretto HTML expectations" do
  it "checks numeric quantities instead of silently accepting any text" do
    quantity = 2
    "<td>2</td>".should have_html { td { quantity } }
    "<td>20</td>".should_not have_html { td { quantity } }
    "<span>19.95</span>".should have_html { span { 19.95 } }
    "<span>1995</span>".should_not have_html { span { 19.95 } }
    "<td>2</td>".should have_html(strict: true) { td { quantity } }
  end

  it "checks scalar flags and characters as literal text" do
    "<output>false</output>".should have_html { output { false } }
    "<output>true</output>".should_not have_html { output { false } }
    "<span>&amp;</span>".should have_html { span { '&' } }
    "<span>A</span>".should_not have_html { span { '&' } }
  end

  it "ignores loop return values when the block records nested requirements" do
    html = "<ol><li>Tea</li><li>Coffee</li></ol>"
    html.should have_html { ol { 2.times { li } } }
    html.should_not have_html { ol { 3.times { li } } }
    html.should have_html { ol { ["Tea", "Coffee"].each { |name| li { name } } } }
  end

  it "allows empty collection loops and conditional nil results" do
    names = [] of String
    "<ul></ul>".should have_html(strict: true) { ul { names.each { |name| li { name } } } }
    "<p></p>".should have_html(strict: true) { p { nil } }
  end

  it "explains unsupported leaf values instead of silently skipping their text" do
    published = Time.utc(2026, 9, 30)
    expect_raises(ArgumentError, "Unsupported HTML text value Time in <time>; use .to_s") do
      "<time>Wrong</time>".should_not have_html { time { published } }
    end
    "<time>2026-09-30 00:00:00 UTC</time>".should have_html { time { published.to_s } }
    "<time>Wrong</time>".should_not have_html { time { published.to_s } }
  end

  it "accepts conditional nested class arrays like Blueprint views" do
    classes = ["field", ["invalid", nil], nil]
    "<input class='wide invalid field'>".should have_html { input(class: classes) }
    "<input class='field'>".should_not have_html { input(class: classes) }
    "<input class='invalid field'>".should have_html(strict: true) { input(class: classes) }
  end

  it "distinguishes false attribute values from absence requirements" do
    html = "<button aria-expanded='false' data-busy='false'>Open</button>"
    html.should have_html {
      button(disabled: false, aria: {expanded: "false"}, data: {busy: "false"}) { "Open" }
    }
    html.should_not have_html { button(aria: {expanded: false}) }
    "<button>Open</button>".should have_html { button(aria: {expanded: false}) }
  end

  it "keeps direct text requirements separate across actual elements" do
    html = "<p>A<!-- build marker -->B<em>Middle</em>AB</p>"
    html.should have_html { p { plain "AB"; em { "Middle" }; plain "AB" } }
    html.should_not have_html { p { plain "ABMiddleAB" } }
    "<p>A<!-- marker -->B<em>Middle</em></p>".should_not have_html {
      p { plain "AB"; em { "Middle" }; plain "AB" }
    }
    "<p>A<!-- marker -->B</p>".should_not have_html { p { plain "A" } }
    "<p>A<!-- marker -->B</p>".should_not have_html { p { plain "B" } }
    "<p>A<em>Middle</em>B</p>".should_not have_html { p { plain "AB" } }
  end

  it "can reuse a matcher after failure without retaining counts or freed document nodes" do
    matcher = have_html(count: 1) { article { h1 { "Tea" } } }
    wrong = "<article><h1>Coffee</h1></article>"
    matcher.match(wrong).should be_false
    matcher.failure_message(wrong).should contain("Coffee")
    "<article><h1>Tea</h1></article>".should matcher
    absent = "<p>Empty</p>"
    matcher.match(absent).should be_false
    message = matcher.failure_message(absent)
    message.should contain("found 0")
    message.should contain("No <article>")
    message.should_not contain("Coffee")
  end

  it "keeps diagnostics readable after many assertions release their parsed documents" do
    50.times do |index|
      matcher = have_html { li { "Tea #{index}" } }
      html = "<ul><li>Coffee #{index}</li></ul>"
      matcher.match(html).should be_false
      matcher.failure_message(html).should contain("Coffee #{index}")
    end
  end

  it "names the complete content requirement when a negative partial assertion fails" do
    response = Caramel::Response.new(200,
      %(<hx-partial hx-target="#notes"><li><strong>Tea</strong></li></hx-partial>))
    failure = expect_raises(Spec::AssertionFailed) do
      response.should_not render_partial("#notes") { li { strong { "Tea" } } }
    end
    failure.message.to_s.should contain(%(containing HTML matching li { strong { "Tea" } }))
    response.should_not render_partial("#notes") { li { strong { "Coffee" } } }
  end

  it "applies sibling distinctness per selected level and strict direct structure" do
    html = "<section><div><div><p>A</p></div></div></section>"
    html.should have_html { section { div { p { "A" } }; div { p { "A" } } } }
    html.should_not have_html(strict: true) {
      section { div { p { "A" } }; div { p { "A" } } }
    }
  end
end
