require "spec"
require "../../frappe/support/events"
require "../../../src/caramel/crema/render"

describe Caramel::Crema::Render do
  it "writes the error, backtrace and queries in that order and omits empty sections" do
    event = EventFixtures.trace("GET /books/:id", failing: true)
    event.spans = [EventFixtures.query("SELECT 1", "app/books.cr:3:1")]
    text = Caramel::Crema::Render.markdown(event, "/proj")
    text.should start_with("# KeyError\n")
    error = text.index!("## Error")
    backtrace = text.index!("## Backtrace")
    queries = text.index!("## Queries")
    (error < backtrace && backtrace < queries).should be_true
    text.should_not contain("## Logs")
    text.should_not contain("## Dumps")
  end

  it "lists the application's frames before the dependencies'" do
    event = EventFixtures.trace("GET /books/:id", failing: true)
    text = Caramel::Crema::Render.markdown(event, "/proj")
    ours = text.index!("app/actions/books/show.cr")
    ours.should be < text.index!("lib/x/y.cr")
  end

  it "shows a request line without the time and level" do
    event = EventFixtures.trace("GET /books/:id")
    line = Caramel::Crema::Render.line(event)
    expected = "request GET /books/:id 200 12.4ms db=2/3.5ms view=0.0ms request_id=req-aaaaaaaa"
    line.should eq(expected)
  end

  it "draws each span as an SVG bar, never an inline style" do
    event = EventFixtures.trace
    event.spans = [EventFixtures.query("SELECT 1")]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain("<svg viewBox=\"0 0 1000 8\" class=\"bar\"><rect")
    html.should_not contain("style=")
  end

  it "escapes SQL in the queries table" do
    event = EventFixtures.trace
    event.spans = [EventFixtures.query("SELECT '<b>' FROM books")]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain("&lt;b&gt;")
    html.should_not contain("<b>")
  end
end

describe Caramel::Crema::Editor do
  it "defaults to Zed and builds a link for an absolute path" do
    link = Caramel::Crema::Editor.from(nil).link("/proj/app/a b.cr", 12, 7)
    link.should eq("zed://file/proj/app/a%20b.cr:12:7")
  end

  it "takes a preset, a template, or falls back to Zed" do
    Caramel::Crema::Editor.from("vscode").link("/a.cr", 1, 2).should eq("vscode://file/a.cr:1:2")
    template = "myeditor://{path}?l={line}&c={column}"
    Caramel::Crema::Editor.from(template).link("/a.cr", 3, 4).should eq("myeditor:///a.cr?l=3&c=4")
    Caramel::Crema::Editor.from("nonsense").link("/a.cr", 1).should eq("zed://file/a.cr:1:1")
  end

  it "refuses a relative path" do
    Caramel::Crema::Editor.from(nil).link("app/a.cr", 1).should eq("")
  end
end
