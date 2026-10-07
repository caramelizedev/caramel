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

  it "adds an Across services section only when another service joined the trace" do
    event = EventFixtures.trace("GET /books/:id")
    own = Caramel::Crema::CollectedSpan.new("bookshelf", "b" * 16, nil, "GET /books/:id", 2,
      1_790_000_000_000_000_000_i64, 1_790_000_000_012_000_000_i64, false, {} of String => String)
    other = Caramel::Crema::CollectedSpan.new("billing", "c" * 16, "b" * 16, "POST /charges", 2,
      1_790_000_000_004_000_000_i64, 1_790_000_000_020_000_000_i64, true, {} of String => String)
    Caramel::Crema::Render.across([own], "bookshelf").should be_empty
    across = Caramel::Crema::Render.across([other, own], "bookshelf")
    across.map(&.service).should eq(%w[bookshelf billing])
    text = Caramel::Crema::Render.markdown(event, nil, across)
    expected = <<-MARKDOWN

      ## Across services

      - bookshelf: GET /books/:id, +0.0 ms, 12.0 ms
      - billing: POST /charges, +4.0 ms, 16.0 ms, error
      MARKDOWN
    text.should contain(expected)
    Caramel::Crema::Render.markdown(event).should_not contain("Across services")
    html = Caramel::Crema::Render.trace_html(event, nil, nil, across)
    html.should contain("<h3>Across services</h3>")
    html.should contain("billing")
    html.should contain("class=\"bar error\"")
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
    html.should contain("<svg viewBox=\"0 0 1000 8\" class=\"bar sql\"><rect")
    html.should_not contain("style=")
  end

  it "writes a statement with its binds in place of the placeholders" do
    sql = %(SELECT * FROM "rates" WHERE "slug" = $1 AND "note" = 'costs $2' AND "n" > $10 LIMIT $2)
    binds = ["o'brien", "50"] + ["x"] * 7 + ["NULL"]
    text = Caramel::Crema::Render.sql_with_values(sql, binds)
    expected = <<-SQL
      SELECT * FROM "rates" WHERE "slug" = 'o''brien' AND "note" = 'costs $2'
        AND "n" > NULL LIMIT '50'
      SQL
    expected = expected.gsub("\n  ", " ")
    text.should eq(expected)
    Caramel::Crema::Render.sql_with_values("SELECT $1, $3", ["a"]).should eq("SELECT 'a', $3")
    Caramel::Crema::Render.sql_with_values("SELECT $1", nil).should eq("SELECT $1")
    Caramel::Crema::Render.sql_with_values("SELECT $1", [] of String).should eq("SELECT $1")
  end

  it "offers to copy a query with and without its values, and warns when binds were cut" do
    event = EventFixtures.trace
    query = EventFixtures.query(%(SELECT 1 WHERE "a" = $1), "app/x.cr:3:1")
    query.binds = ["v"]
    cut = EventFixtures.query(%(SELECT 2 WHERE "a" = $1), "app/x.cr:4:1")
    cut.binds = ["z" * 200]
    bare = EventFixtures.query("SELECT 3")
    event.spans = [query, cut, bare]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    values = %(<pre hidden id="sql-1-values">SELECT 1 WHERE &quot;a&quot; = &#39;v&#39;</pre>)
    html.should contain(values)
    html.should contain(%(data-caramel-copy="sql-1"))
    html.should contain("-- Some bind values were cut short when recorded.")
    html.should contain(%(id="sql-3">SELECT 3</pre>))
    html.should_not contain("sql-3-values")
  end

  it "links the timeline to the queries, indents what a view contains and colours by kind" do
    event = EventFixtures.trace
    view = Caramel::Crema::SpanEvent.new("view", "Page", 10.0, 50.0)
    inside = Caramel::Crema::SpanEvent.new("sql", "SELECT a", 20.0, 2.0)
    inside.detail = "SELECT 1"
    outside = Caramel::Crema::SpanEvent.new("sql", "SELECT b", 70.0, 2.0)
    outside.detail = "SELECT 2"
    event.spans = [view, inside, outside]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain(%(<h3 id="timeline">))
    html.should contain(%(<h3 id="queries">))
    html.should contain(%(<td class="d1"><a href="#q1">SELECT a</a></td>))
    html.should contain(%(<td class="d0"><a href="#q2">SELECT b</a></td>))
    html.should contain(%(class="bar view"))
    html.should contain(%(<tr id="q2"))
    html.should contain("Duration</th><th>SQL")
    html.should_not contain("<h2>")
  end

  it "marks a repeated query, names its source and says what to do" do
    event = EventFixtures.trace
    sql = %(SELECT "authors".* FROM "authors" WHERE "id" = $1)
    event.spans = [EventFixtures.query(sql, "app/v.cr:8:5")]
    event.repeated = [Caramel::Crema::RepeatEvent.new(sql, 6, "app/v.cr:8:5")]
    html = Caramel::Crema::Render.trace_html(event, Caramel::Crema::Editor.from(nil), "/proj")
    html.should contain(%(<tr id="q1" class="repeated">))
    html.should contain("ran 6 times")
    html.should contain("Ran 6 times")
    html.should contain("zed://file/proj/app/v.cr:8:5")
    html.should contain(".preload(:author)")
  end

  it "lists your frames with editor links on the error section, the rest folded" do
    event = EventFixtures.trace(failing: true)
    html = Caramel::Crema::Render.trace_html(event, Caramel::Crema::Editor.from(nil), "/proj")
    html.should contain(%(<h3 id="error">))
    html.should contain("<h4>Backtrace</h4>")
    html.should contain("zed://file/proj/app/actions/books/show.cr:12:7")
    html.should contain("1 other frames")
    html.index!("app/actions/books/show.cr").should be < html.index!("lib/x/y.cr")
  end

  it "escapes SQL in the queries table" do
    event = EventFixtures.trace
    event.spans = [EventFixtures.query("SELECT '<b>' FROM books")]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain("&lt;b&gt;")
    html.should_not contain("<b>")
  end

  it "fences code longer than any backtick run it holds" do
    event = EventFixtures.trace
    event.spans = [EventFixtures.query("SELECT '```' FROM books")]
    text = Caramel::Crema::Render.markdown(event)
    text.should contain("````sql\nSELECT '```' FROM books\n````\n")
  end

  it "keeps single-line fields on one line" do
    event = EventFixtures.trace("GET /books/:id", failing: true)
    event.error.try(&.message = "first\n## Injected")
    text = Caramel::Crema::Render.markdown(event)
    text.should contain("- message: first ## Injected\n")
  end

  it "redacts bind values and dump text in the Markdown" do
    event = EventFixtures.trace
    query = EventFixtures.query("SELECT 1")
    query.binds = ["password=hunter2"]
    dump = Caramel::Crema::SpanEvent.new("dump", "app/x.cr:3", 0.0, 0.0)
    dump.detail = "token=abc123"
    event.spans = [query, dump]
    text = Caramel::Crema::Render.markdown(event)
    text.should_not contain("hunter2")
    text.should_not contain("abc123")
  end

  it "tolerates a started_at too short for a clock time" do
    event = EventFixtures.trace(at: "now")
    html = Caramel::Crema::Render.traces_table_html([event], "/t/")
    html.should contain("<td>now</td>")
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
