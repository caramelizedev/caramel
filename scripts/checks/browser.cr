require "./support/latte_fixture"
require "./support/webdriver"
require "uri"
require "http/params"

module Caramel::Checks
  # Drives Safari against a generated app served through Latte's Caddy to
  # prove the hypermedia promises that only a real browser can observe.
  class BrowserCheck
    PROBE = File.join(REPO, "spec/fixtures/browser")
    NAME  = "browser"

    DIAGNOSTICS = <<-'JS'
      const region = document.querySelector(arguments[0]);
      const active = document.activeElement;
      return JSON.stringify({
        url: location.href,
        activeElement: active ? active.outerHTML.slice(0, 400) : null,
        region: region ? region.outerHTML.slice(0, 8000) : `nothing matches ${arguments[0]}`,
        probe: window.__probe ?? null,
      }, null, 2);
      JS

    SEARCH_STATE = <<-'JS'
      const input = document.getElementById(`search-${arguments[0]}-q`);
      const list = document.getElementById(`search-${arguments[0]}-results`);
      const active = document.activeElement;
      const probe = window.__probe;
      return {
        sameInput: active === window.__refs.input,
        storedInputConnected: window.__refs.input.isConnected,
        sameList: list === window.__refs.list,
        active: active ? `${active.tagName.toLowerCase()}#${active.id}` : null,
        value: input.value,
        selectionStart: input.selectionStart,
        selectionEnd: input.selectionEnd,
        scrollTop: list.scrollTop,
        first: list.querySelector('li')?.textContent ?? null,
        headers: document.querySelectorAll('header.site-header').length,
        request: probe.requests.at(-1) ?? null,
        response: probe.responses.at(-1) ?? null,
      };
      JS

    ISLAND_STATE = <<-'JS'
      const island = document.querySelector('caramel-island[component="ProbeCounter"]');
      const late = document.querySelector('caramel-island[component="LateProbe"]');
      const refs = window.__refs || {};
      return {
        log: window.__probe.islands,
        present: Boolean(island),
        storedConnected: refs.island ? refs.island.isConnected : null,
        sameIsland: Boolean(island) && island === refs.island,
        sameButton: Boolean(island) && island.querySelector('.island-increment') === refs.button,
        state: island ? island.dataset.islandState ?? null : null,
        props: island ? island.getAttribute('props') : null,
        label: island?.querySelector('.island-label')?.textContent ?? null,
        count: island?.querySelector('.island-count')?.textContent ?? null,
        lateState: late ? late.dataset.islandState ?? null : null,
        lateText: late ? late.textContent : null,
        inflight: window.__probe.inflight,
      };
      JS

    @driver : WebDriver?

    def initialize
      toolchain = Checks.toolchain_root
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @fixture = LatteFixture.new("caramel-browser-")
      @project = File.join(@fixture.projects, NAME)
      @origin = ""
      @database_url = ""
    end

    def execute : Nil
      started = Time.instant
      fixture = @fixture
      puts "Browser fixture: #{fixture.root}"
      failed = true
      begin
        fixture.start
        values = create_project
        @database_url = values["DATABASE_URL"]
        @origin = "https://#{NAME}.localhost:#{fixture.https_port}"
        fixture.serve(@project, NAME, values.merge({"APP_ORIGIN" => @origin}))
        File.open(File.join(fixture.root, "safaridriver.log"), "w") do |log|
          WebDriver.open(log) do |driver|
            @driver = driver
            check_morph
            check_partials
            check_islands
            check_events
            check_pubsub
            check_graceful_stop
          ensure
            @driver = nil
          end
        end
        failed = false
      ensure
        fixture.finish(failed)
      end
      puts "Browser check finished in #{(Time.instant - started).total_seconds.round(1)}s"
    end

    # Exercises the real CLI: a new project moves from the default suffix to
    # `localhost`, which Safari resolves to loopback without system DNS.
    private def create_project : Hash(String, String)
      fixture = @fixture
      frappe = File.join(fixture.repo, "bin/frappe")
      fixture.command([frappe, "new", NAME], chdir: fixture.projects)
      fixture.command([frappe, "sites", "remove", NAME], echo: false)
      manifest = File.join(@project, "config/environment.yml")
      original = File.read(manifest)
      switched = original.sub("domain_suffix: caramel", "domain_suffix: localhost")
      assert!(switched != original, "Generated environment.yml lacks domain_suffix: caramel")
      File.write(manifest, switched)
      File.delete(File.join(@project, ".env"))
      fixture.command([frappe, "setup"], chdir: @project)
      fixture.trust_guard!
      site = fixture.site(NAME)
      assert!(site["suffix"].as_s == "localhost", "Site did not re-register with the localhost suffix: #{site.to_json}")
      values = fixture.local_values(@project)
      assert!(values["APP_ORIGIN"] == "https://#{NAME}.localhost", "Unexpected APP_ORIGIN: #{values["APP_ORIGIN"]}")
      install_probe
      fixture.command([frappe, "migrate"], chdir: @project)
      values
    end

    private def install_probe : Nil
      %w(app/actions/probe app/views/probe).each do |relative|
        FileUtils.cp_r(File.join(PROBE, relative), File.join(@project, relative))
      end
      %w(app/jobs/probe_delivery.cr db/migrations/20260927130000_create_probe_deliveries.cr).each do |relative|
        File.copy(File.join(PROBE, relative), File.join(@project, relative))
      end
      routes = File.join(@project, "config/routes.cr")
      marker = "    # Frappé resource routes\n"
      source = File.read(routes)
      assert!(source.includes?(marker), "Generated routes lack the resource-route marker")
      File.write(routes, source.sub(marker, File.read(File.join(PROBE, "routes.cr")) + marker))
      # The native app serves public/; only frappe dev republishes app/assets.
      {"javascript/app.js" => "app.js", "stylesheets/app.css" => "app.css"}.each do |relative, name|
        asset = File.join(@project, "app/assets", relative)
        File.write(asset, File.read(asset) + File.read(File.join(PROBE, "assets", name)))
        File.copy(asset, File.join(@project, "public/assets", name))
      end
    end

    private def check_morph : Nil
      group("morph live search", "#content") do
        visit("/probe/search")
        remember("input: document.getElementById('search-morph-q'), list: document.getElementById('search-morph-results')")
        state = type_search("morph", "caramel", "caramel")
        assert!(state["sameInput"].as_bool && state["storedInputConnected"].as_bool, "innerMorph did not keep the focused input instance: #{state.to_json}")
        assert!(state["value"] == "caramel" && state["selectionStart"] == 7 && state["selectionEnd"] == 7, "Typed value or caret changed: #{state.to_json}")
        assert!(state["first"] == "caramel 1", "Server results were not swapped in: #{state.to_json}")
        assert!(state["headers"] == 1 && state["request"]["type"] == "partial" && state["response"]["layout"] == false, "The swap was not a layout-free fragment: #{state.to_json}")
        scrolled = number(js("const list = document.getElementById('search-morph-results'); list.scrollTop = 300; return list.scrollTop"))
        assert!(scrolled == 300, "The results list is not scrollable to 300px: #{scrolled}")
        state = type_search("morph", "s", "caramels")
        assert!(state["first"] == "caramels 1" && state["sameList"].as_bool, "The second swap did not morph the list: #{state.to_json}")
        assert!((number(state["scrollTop"]) - 300).abs <= 1, "innerMorph lost the list scroll position: #{state.to_json}")
        assert!(state["sameInput"].as_bool && state["value"] == "caramels" && state["selectionStart"] == 8 && state["selectionEnd"] == 8, "Focus, value or caret changed after the second swap: #{state.to_json}")
        puts "PASS: innerMorph live search kept the same focused input (value and caret intact) and list scrollTop #{scrolled.to_i} -> #{state["scrollTop"]} across two server swaps of a layout-free fragment"

        remember("input: document.getElementById('search-html-q'), list: document.getElementById('search-html-results')")
        js("document.getElementById('search-html-results').scrollTop = 300")
        state = type_search("html", "caramel", "caramel")
        assert!(state["first"] == "caramel 1", "The innerHTML control did not swap: #{state.to_json}")
        assert!(!state["sameInput"].as_bool && !state["storedInputConnected"].as_bool, "innerHTML unexpectedly kept the input instance, so the morph assertion proves nothing: #{state.to_json}")
        assert!(state["scrollTop"] == 0 && !state["sameList"].as_bool, "innerHTML unexpectedly kept the list scroll: #{state.to_json}")
        puts "PASS: innerHTML control replaced the focused input and reset scrollTop 300 -> 0, so the morph assertions can fail"
      end
    end

    private def check_partials : Nil
      group("hx-partial multi-target POST", "#content") do
        visit("/probe/roster")
        baseline = js(<<-'JS').as_i
          const note = document.getElementById('roster-note');
          note.probeMarker = 'untouched';
          window.__refs = { note, content: document.getElementById('content'), form: document.getElementById('enroll') };
          return window.__probe.requests.length;
          JS
        driver.send_keys(driver.find("#enroll-name"), "Katherine Johnson")
        driver.click(driver.find("#enroll-submit"))
        wait_for("the roster count to reach 3") do
          js("return window.__probe.inflight === 0 && document.getElementById('roster-count').textContent === '3'").as_bool
        end
        state = js(<<-'JS', baseline)
          const note = document.getElementById('roster-note');
          return {
            requests: window.__probe.requests.slice(arguments[0]),
            responses: window.__probe.responses.slice(arguments[0]),
            roster: [...document.querySelectorAll('#roster li')].map((item) => item.textContent),
            count: document.getElementById('roster-count').textContent,
            noteSame: note === window.__refs.note,
            noteMarker: note.probeMarker ?? null,
            noteText: note.textContent,
            contentSame: document.getElementById('content') === window.__refs.content,
            formSame: document.getElementById('enroll') === window.__refs.form,
          };
          JS
        requests = state["requests"].as_a
        assert!(requests.size == 1 && requests[0]["method"] == "POST" && requests[0]["csrf"] == true, "Expected exactly one CSRF-carrying POST: #{state.to_json}")
        assert!(state["responses"].as_a.map(&.["status"]) == [200], "The POST did not succeed: #{state.to_json}")
        assert!(state["roster"].as_a.map(&.as_s) == ["Ada Lovelace", "Grace Hopper", "Katherine Johnson"] && state["count"] == "3", "Both targets did not update: #{state.to_json}")
        assert!(state["noteSame"].as_bool && state["noteMarker"] == "untouched" && state["noteText"] == "This region is not part of any response.", "An unrelated region changed: #{state.to_json}")
        assert!(state["contentSame"].as_bool && state["formSame"].as_bool, "The main target was swapped: #{state.to_json}")
        puts "PASS: one CSRF-protected htmx POST updated #roster (innerMorph) and #roster-count (innerHTML) through hx-partial; #roster-note and the form stayed untouched"
      end
    end

    private def check_islands : Nil
      group("islands lifecycle", "#content") do
        visit("/probe/islands")
        wait_for("the ProbeCounter island to mount") { island_state["state"] == "mounted" }
        state = island_state
        assert!(state["log"].to_json == %([{"event":"mount","component":"ProbeCounter","props":{"label":"first","version":1}}]), "Mount did not receive the server props exactly once: #{state.to_json}")
        assert!(state["label"] == "first" && state["count"] == "0", "Mount did not render client children: #{state.to_json}")
        assert!(state["lateState"] == "pending", "An island without a definition is not pending: #{state.to_json}")
        remember("island: document.querySelector('caramel-island[component=\"ProbeCounter\"]'), button: document.querySelector('.island-increment')")
        2.times { driver.click(driver.find("caramel-island .island-increment")) }
        assert!(island_state["count"] == "2", "The client button did not change client state: #{island_state.to_json}")
        driver.click(driver.find("#island-morph"))
        wait_for("the morph to re-render the island with new props") do
          current = island_state
          current["inflight"] == 0 && current["props"].as_s? == %({"label":"second","version":2})
        end
        state = island_state
        log = state["log"].as_a
        assert!(log.size == 2 && log[1].to_json == %({"event":"update","component":"ProbeCounter","props":{"label":"second","version":2}}), "update(props) was not called exactly once with the new props: #{state.to_json}")
        assert!(state["sameIsland"].as_bool && state["sameButton"].as_bool && state["count"] == "2" && state["label"] == "second", "Client-owned children or state did not survive the morph: #{state.to_json}")
        assert!(state["state"] == "mounted", "The morph dropped data-island-state from a mounted island: #{state.to_json}")
        driver.click(driver.find("#island-remove"))
        wait_for("the swap that removes the island") do
          js("return window.__probe.inflight === 0 && Boolean(document.getElementById('island-removed'))").as_bool
        end
        state = island_state
        log = state["log"].as_a
        assert!(log.size == 3 && log[2].to_json == %({"event":"unmount","component":"ProbeCounter"}) && state["storedConnected"] == false, "Removing the island did not unmount it: #{state.to_json}")
        puts "PASS: island mounted with server props; a morph with new props called update(props) and kept client children and state (count 2); removal called unmount()"
        assert!(state["lateState"] == "pending", "The late island mounted before its definition: #{state.to_json}")
        driver.click(driver.find("#define-late"))
        wait_for("the late island to mount") { island_state["lateState"] == "mounted" }
        state = island_state
        assert!(state["log"].as_a.last.to_json == %({"event":"mount","component":"LateProbe","props":{"label":"late"}}) && state["lateText"] == "Mounted late", "The late definition did not mount the pending island: #{state.to_json}")
        puts "PASS: an island connected before CaramelIslands.define went pending -> mounted when its component was defined"
      end
    end

    private def check_events : Nil
      group("server-sent events through Caddy", "#content") do
        visit("/probe/events")
        opened = Time.instant
        driver.click(driver.find("#sse-open"))
        wait_for("the first event before release", 15.seconds) { js("return window.__probe.sse.length > 0").as_bool }
        first = Time.instant - opened
        events = js("return window.__probe.sse.map((event) => event.data)")
        assert!(events.as_a.map(&.as_s) == ["first"], "Unexpected events before release: #{events.to_json}")
        fixture = @fixture
        released = Time.instant
        release = fixture.command(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "10", "--noproxy", "*", "--cacert", fixture.certificate,
                                   "--resolve", "#{NAME}.localhost:#{fixture.https_port}:127.0.0.1", "#{@origin}/probe/events/release"], echo: false, timeout: 15.seconds)
        assert!(release.stdout == "released", "The release endpoint did not find a waiting stream: #{release.stdout}")
        wait_for("the second event after release", 15.seconds) { js("return window.__probe.sse.length > 1").as_bool }
        second = Time.instant - released
        state = js("return {events: window.__probe.sse.map((event) => event.data), errors: window.__probe.sseErrors}")
        assert!(state["events"].as_a.map(&.as_s) == ["first", "second"] && state["errors"].as_a.empty?, "Unexpected stream state: #{state.to_json}")
        puts "PASS: SSE through Caddy to the app socket delivered event 1 before release (#{first.total_milliseconds.round.to_i} ms after opening) and event 2 after release (#{second.total_milliseconds.round.to_i} ms later)"
      end
    end

    # The page streams the RFC-0003 §2.3 action; a POST commits a business row
    # with its job; serve's worker runs the job, whose publish reaches Safari.
    private def check_pubsub : Nil
      group("Cold Brew job to PubSub through Caddy", "#pubsub") do
        visit("/probe/pubsub")
        driver.click(driver.find("#pubsub-open"))
        # That action sends its headers with its first event: ping until one arrives.
        live = false
        deadline = Time.instant + 15.seconds
        until live || Time.instant > deadline
          driver.click(driver.find("#pubsub-ping"))
          live = Checks.wait_until(1.second, 50.milliseconds) { js("return window.__probe.pubsub.includes('ping')").as_bool }
        end
        assert!(live, "No ping reached the board stream within 15 s: #{js("return window.__probe.pubsubErrors").to_json}")
        requested = Time.instant
        driver.click(driver.find("#pubsub-deliver"))
        wait_for("the delivery POST to answer") { js("return document.getElementById('pubsub-delivery').textContent !== ''").as_bool }
        delivery = js("return document.getElementById('pubsub-delivery').textContent").as_s.to_i64
        wait_for("the job's event", 15.seconds) { js("return window.__probe.pubsub.some((data) => data !== 'ping')").as_bool }
        latency = Time.instant - requested
        state = js("return {events: window.__probe.pubsub.filter((data) => data !== 'ping'), errors: window.__probe.pubsubErrors, requests: window.__probe.requests.filter((request) => request.method === 'POST')}")
        assert!(state["events"].as_a.map(&.as_s) == [{delivery: delivery}.to_json] && state["errors"].as_a.empty?, "Unexpected board stream state: #{state.to_json}")
        assert!(state["requests"].as_a.all? { |request| request["csrf"] == true }, "A probe POST lacked CSRF: #{state.to_json}")
        assert!(job_state(delivery) == "1:true:true:default", "The job row is not finished after one attempt: #{job_state(delivery).inspect}")
        assert!(sql("SELECT delivered_at IS NOT NULL FROM probe_deliveries WHERE id = #{delivery}") == "t", "The job's write did not commit")
        puts "PASS: a POST committed delivery #{delivery} with its Cold Brew job; serve's worker finished the job (1 attempt) and its publish reached Safari's EventSource on the RFC-0003 §2.3 action through Caddy #{latency.total_milliseconds.round.to_i} ms after the click"
      end
    end

    # SIGTERM while a job runs: serve stops fetching, lets the job finish and exits.
    private def check_graceful_stop : Nil
      group("Cold Brew graceful stop on SIGTERM", "#pubsub") do
        previous = js("return document.getElementById('pubsub-delivery').textContent").as_s
        driver.click(driver.find("#pubsub-deliver-slow"))
        wait_for("the slow delivery POST to answer") { js("return document.getElementById('pubsub-delivery').textContent !== arguments[0]", previous).as_bool }
        delivery = js("return document.getElementById('pubsub-delivery').textContent").as_s.to_i64
        wait_for("serve's worker to start the slow job") { job_state(delivery) == "1:false:true:default" }
        app = @fixture.app || raise "The fixture app is not running"
        stopping = Time.instant
        app.signal(Signal::TERM)
        status = LatteFixture.wait_exit(app, 15.seconds, "serve to exit after SIGTERM")
        stopped = Time.instant - stopping
        assert!(status.success?, "serve exited with #{status} after SIGTERM")
        assert!(job_state(delivery) == "1:true:true:default", "The in-flight job did not finish before exit: #{job_state(delivery).inspect}")
        assert!(sql("SELECT delivered_at IS NOT NULL FROM probe_deliveries WHERE id = #{delivery}") == "t", "The in-flight job's write did not commit")
        puts "PASS: SIGTERM while delivery #{delivery}'s job ran: serve let the job finish (1 attempt, committed) and exited 0 after #{stopped.total_milliseconds.round.to_i} ms"
      end
    end

    # attempts:finished:not failed:queue of the delivery's job.
    private def job_state(delivery : Int64) : String
      sql(<<-SQL)
        SELECT attempts || ':' || (finished_at IS NOT NULL) || ':' || (failed_at IS NULL) || ':' || queue
        FROM caramel_jobs WHERE class_name = 'App::ProbeDelivery' AND (payload->>'delivery_id')::bigint = #{delivery}
        SQL
    end

    private def sql(statement : String) : String
      uri = URI.parse(@database_url)
      query = HTTP::Params.parse(uri.query || "")
      environment = @fixture.environment({"PGPASSWORD" => URI.decode(uri.password || "")})
      @fixture.command([@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", query["host"], "-p", query["port"]? || "5432", "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')],
        environment: environment, input: statement, echo: false, timeout: 15.seconds).stdout.strip
    end

    private def type_search(mode : String, keys : String, query : String) : JSON::Any
      driver.send_keys(driver.find("#search-#{mode}-q"), keys)
      wait_for("the #{mode} panel to render results for #{query.inspect}") do
        js("return window.__probe.inflight === 0 && document.getElementById(arguments[0]).dataset.query === arguments[1]", "search-#{mode}-results", query).as_bool
      end
      js(SEARCH_STATE, mode)
    end

    private def number(value : JSON::Any) : Float64
      value.as_i64?.try(&.to_f) || value.as_f
    end

    private def island_state : JSON::Any
      js(ISLAND_STATE)
    end

    # Keeps element references in the page so later checks compare identity.
    private def remember(entries : String) : Nil
      js("window.__refs = { #{entries} }")
    end

    private def visit(path : String) : Nil
      driver.navigate(@origin + path)
      wait_for("#{path} to load htmx, islands and the probe script") do
        js("return document.readyState === 'complete' && Boolean(window.htmx && window.CaramelIslands && window.__probe)").as_bool
      end
    end

    private def group(name : String, selector : String, &) : Nil
      yield
    rescue ex
      raise "FAIL: #{name}: #{ex.message}\n#{diagnostics(selector)}"
    end

    private def diagnostics(selector : String) : String
      js(DIAGNOSTICS, selector).as_s
    rescue ex
      "(page diagnostics unavailable: #{ex.message})"
    end

    private def wait_for(description : String, timeout : Time::Span = 10.seconds, &condition : -> Bool) : Nil
      return if Checks.wait_until(timeout, 50.milliseconds, &condition)
      raise "Timed out after #{timeout.total_seconds.to_i}s waiting for #{description}"
    end

    private def js(script : String, *args) : JSON::Any
      driver.execute(script, *args)
    end

    private def driver : WebDriver
      @driver || raise "No browser session"
    end

    private def assert!(condition : Bool, message : String) : Nil
      raise message unless condition
    end
  end
end

begin
  Caramel::Checks::BrowserCheck.new.execute
rescue ex
  STDERR.puts ex.message
  exit 1
end
