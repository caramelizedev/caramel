require "spec"
require "../../frappe/support/events"
require "../../../src/caramel"
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
    html.should contain("preserveAspectRatio=\"none\" aria-hidden=\"true\" class=\"bar sql\"><rect")
    html.should_not contain("style=")
  end

  it "writes a statement with its values: literals when it has them, else its binds quoted" do
    sql = %(SELECT * FROM "rates" WHERE "slug" = $1 AND "n" > $2 LIMIT $3)
    render = Caramel::Crema::Render
    nothing = Caramel::Crema::NULL_BIND
    render.sql_with_values(sql, ["o'brien", nothing, "50"]).should eq(
      %(SELECT * FROM "rates" WHERE "slug" = 'o''brien' AND "n" > NULL LIMIT '50'))
    render.sql_with_values(sql, ["x", "1", "2"], ["'x'", "1", "50"]).should eq(
      %(SELECT * FROM "rates" WHERE "slug" = 'x' AND "n" > 1 LIMIT 50))
    render.sql_with_values("SELECT $1", nil).should eq("SELECT $1")
    render.sql_with_values("SELECT $1", [] of String).should eq("SELECT $1")
  end

  it "shows a nil bind as a bare NULL and the text NULL as a quoted string" do
    binds = [Caramel::Crema::NULL_BIND, "NULL", "a\"b"]
    Caramel::Crema::Render.binds_text(binds).should eq(%([NULL, "NULL", "a\\"b"]))
    copied = Caramel::Crema::Render.sql_with_values("SELECT $1, $2", binds)
    copied.should eq("SELECT NULL, 'NULL'")
  end

  it "offers to copy a query with and without its values, and warns when some stay unfilled" do
    event = EventFixtures.trace
    query = EventFixtures.query(%(SELECT 1 WHERE "a" = $1), "app/x.cr:3:1")
    query.binds = ["v"]
    query.literals = ["'v'"]
    cut = EventFixtures.query(%(SELECT 2 WHERE "a" = $1 AND "b" = $2), "app/x.cr:4:1")
    cut.binds = ["z"]
    cut.literals = ["'z'"]
    bare = EventFixtures.query("SELECT 3")
    event.spans = [query, cut, bare]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain(%(data-caramel-text="SELECT 1 WHERE &quot;a&quot; = &#39;v&#39;"))
    html.should contain(%(data-caramel-text="SELECT 1 WHERE &quot;a&quot; = $1"))
    html.should contain("-- Some values could not be filled in; their $n stays.")
    html.should contain(%(data-caramel-text="SELECT 3"))
    html.scan("Copy with values").size.should eq(2)
    html.should_not contain("<pre hidden")
  end

  it "renders no value, literal or values button for a production-detail trace" do
    span = Caramel::Crema::Span.new(Caramel::Crema::SpanKind::Sql, "SELECT books", Time::Span.zero)
    span.detail = %(SELECT * FROM "books" WHERE "token" = $1)
    span.binds = ["hunter2"]
    span.literals = ["'hunter2'"]
    production = span.to_event(Caramel::Crema::Detail::Production)
    production.binds.should be_nil
    production.literals.should be_nil
    event = EventFixtures.trace
    event.spans = [production]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should_not contain("hunter2")
    html.should_not contain("Copy with values")
    html.should contain(">Copy SQL</button>")
    span.to_event(Caramel::Crema::Detail::Development).literals.should eq(["'hunter2'"])
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
    html.should contain("Likely fix:")
    Caramel::Crema::Render.preload_hint(%(INSERT INTO "authors" ("a") VALUES ($1))).should be_nil
    Caramel::Crema::Render.preload_hint("SELECT 1").should be_nil
  end

  it "shows the first frames openly when none of them is your application's" do
    event = EventFixtures.trace(failing: true)
    event.error.try(&.backtrace = ["lib/a/b.cr:1:1 in 'A#b'", "lib/c/d.cr:2:2 in 'C#d'"])
    html = Caramel::Crema::Render.trace_html(event, nil, "/proj")
    html.should contain("<li>lib/a/b.cr:1:1 in <code>A#b</code></li>")
    html.should_not contain("other frames")
  end

  it "marks a failed span's bar" do
    event = EventFixtures.trace
    failed = Caramel::Crema::SpanEvent.new("http", "GET api.example", 1.0, 2.0)
    failed.error_class = "IO::Error"
    event.spans = [failed]
    Caramel::Crema::Render.trace_html(event, nil, nil).should contain(%(class="bar http error"))
  end

  it "shows the binds the way the copied statement writes them" do
    render = Caramel::Crema::Render
    nothing = Caramel::Crema::NULL_BIND
    binds = ["42", "acme", nothing, "NULL", "x"]
    literals = ["42", "'acme'", "NULL", "'NULL'", ""]
    render.binds_display(binds, literals).should eq(%([42, 'acme', NULL, 'NULL', "x"]))
    render.binds_display(binds, nil).should eq(%(["42", "acme", NULL, "NULL", "x"]))
    render.binds_display(nil, nil).should be_nil
    long = "'#{"y" * 300}'"
    shown = render.binds_display(["y" * 300], [long]).to_s
    shown.should eq("['#{"y" * 201}…]")
  end

  it "keeps the toolbar's links on the page when a trace has no spans, queries or error report" do
    event = EventFixtures.trace
    event.outcome = "error"
    event.error = nil
    event.spans = [] of Caramel::Crema::SpanEvent
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain(%(<h3 id="timeline">Timeline</h3><p>No spans were recorded))
    html.should contain(%(<h3 id="queries">Queries</h3><p>No query text was recorded))
    html.should contain(%(<h3 id="error">Error</h3><p>No error report was recorded.</p>))
    event.outcome = "ok"
    Caramel::Crema::Render.trace_html(event, nil, nil).should_not contain(%(id="error"))
    event.spans = [Caramel::Crema::SpanEvent.new("view", "Page", 0.0, 1.0)]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    html.should contain(%(<h3 id="queries">Queries</h3><p>No query text was recorded))
    html.should_not contain("No spans were recorded")
  end

  it "does not mark a bind that fits as cut, and marks one that does not" do
    render = Caramel::Crema::Render
    fits = "y" * 200
    render.binds_display([fits], ["'#{fits}'"]).should eq("['#{fits}']")
    many = "y" * 300
    shown = render.binds_display([many], ["'#{many}'"]).to_s
    shown.should end_with("…]")
    shown.bytesize.should be < 215
  end

  it "keeps the ids the toolbar links to" do
    event = EventFixtures.trace(failing: true)
    event.spans = [EventFixtures.query("SELECT 1", "app/x.cr:3:1")]
    html = Caramel::Crema::Render.trace_html(event, nil, nil)
    %w[timeline queries error].each { |anchor| html.should contain(%(id="#{anchor}")) }
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

  it "writes an error outside a trace as Markdown" do
    error = EventFixtures.error
    error.backtrace = ["lib/a/b.cr:1:1 in 'A#b'"]
    text = Caramel::Crema::Render.markdown(error)
    text.should start_with("# KeyError\n\n")
    text.should contain("## Error")
    text.should contain("## Backtrace")
  end

  it "keeps an error outside a trace from injecting headings" do
    error = EventFixtures.error
    error.message = "first\n## Injected"
    text = Caramel::Crema::Render.markdown(error)
    text.should contain("- message: first ## Injected\n")
    text.should_not contain("\n## Injected")
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
