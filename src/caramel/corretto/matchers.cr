require "html"

module Corretto
  # Expectations for `should`/`should_not`; `Corretto::Matchers` builds them.
  # Failure messages show the relevant part of the response.
  module Expectations
    def self.excerpt(response : Caramel::Response) : String
      body = response.body.size > 800 ? "#{response.body[0, 800]}…" : response.body
      headers = response.headers.compact_map do |name, values|
        "  #{name}: #{values.join(", ")}" unless name.in?("Content-Security-Policy", "Set-Cookie")
      end
      "Response status #{response.status}\n#{headers.join('\n')}\n  Body: #{body.empty? ? "(empty)" : body}"
    end

    struct HaveStatus
      def initialize(@status : Int32)
      end

      def match(response : Caramel::Response) : Bool
        response.status == @status
      end

      def failure_message(response : Caramel::Response) : String
        "Expected status #{@status}, got #{response.status}\n#{Expectations.excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected a status other than #{@status}\n#{Expectations.excerpt(response)}"
      end
    end

    struct RenderPartial
      PARTIAL = /<hx-partial hx-target="([^"]*)" hx-swap="([^"]*)">/

      def initialize(@target : String, @swap : String?)
      end

      def match(response : Caramel::Response) : Bool
        partials(response).any? { |(target, swap)| target == @target && (@swap.nil? || swap == @swap) }
      end

      def failure_message(response : Caramel::Response) : String
        found = partials(response).join(", ") { |(target, swap)| "#{target} (#{swap})" }
        "Expected an <hx-partial> for #{description}; found #{found.empty? ? "none" : found}\n#{Expectations.excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no <hx-partial> for #{description}\n#{Expectations.excerpt(response)}"
      end

      private def description : String
        @swap ? "#{@target} swapped with #{@swap}" : @target
      end

      private def partials(response : Caramel::Response) : Array({String, String})
        response.body.scan(PARTIAL).map { |match| {::HTML.unescape(match[1]), match[2]} }
      end
    end

    struct RedirectTo
      def initialize(@path : String)
      end

      def match(response : Caramel::Response) : Bool
        ((300..399).includes?(response.status) && response.headers["Location"]? == @path) || response.headers["HX-Location"]? == @path
      end

      def failure_message(response : Caramel::Response) : String
        "Expected a redirect (Location or HX-Location) to #{@path}\n#{Expectations.excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no redirect to #{@path}\n#{Expectations.excerpt(response)}"
      end
    end

    struct HaveHeader
      def initialize(@name : String, @value : String?)
      end

      def match(response : Caramel::Response) : Bool
        values = response.headers.get?(@name)
        return false unless values
        value = @value
        value.nil? || values.includes?(value)
      end

      def failure_message(response : Caramel::Response) : String
        "Expected header #{description}\n#{Expectations.excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no header #{description}\n#{Expectations.excerpt(response)}"
      end

      private def description : String
        @value ? "#{@name}: #{@value}" : @name
      end
    end

    struct RenderPage
      def initialize(@title : String)
      end

      def match(response : Caramel::Response) : Bool
        return false unless response.body.matches?(/\A\s*<!DOCTYPE html>/i)
        title(response).try(&.includes?(@title)) || false
      end

      def failure_message(response : Caramel::Response) : String
        "Expected a full HTML page titled #{@title.inspect}; got #{title(response).try(&.inspect) || "no <title>"}\n#{Expectations.excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no full HTML page titled #{@title.inspect}\n#{Expectations.excerpt(response)}"
      end

      private def title(response : Caramel::Response) : String?
        response.body.match(/<title>(.*?)<\/title>/m).try { |match| ::HTML.unescape(match[1]) }
      end
    end

    struct HaveRow(T, Q, C)
      def initialize(@schema : T.class, @query : Q, @conditions : C)
      end

      def match(db : SugarORM::Handle) : Bool
        @query.exists?(db)
      end

      def failure_message(db : SugarORM::Handle) : String
        "Expected #{T} to have a row where #{description}; none matched among #{T.query.count(db)} rows"
      end

      def negative_failure_message(db : SugarORM::Handle) : String
        "Expected #{T} to have no row where #{description}; #{@query.count(db)} matched"
      end

      private def description : String
        @conditions.empty? ? "(any)" : @conditions.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      end
    end
  end

  # `response.should have_status(200)`, `db.should have_row(App::Book, title: "Dune")`, …
  module Matchers
    def have_status(status : Int32) : Expectations::HaveStatus
      Expectations::HaveStatus.new(status)
    end

    # Matches an `<hx-partial>` block for `target`, and its `hx-swap` when given.
    def render_partial(target : String, swap : String? = nil) : Expectations::RenderPartial
      Expectations::RenderPartial.new(target, swap)
    end

    # A 3xx `Location` or an htmx `HX-Location` equal to `path`.
    def redirect_to(path : String) : Expectations::RedirectTo
      Expectations::RedirectTo.new(path)
    end

    def have_header(name : String, value : String? = nil) : Expectations::HaveHeader
      Expectations::HaveHeader.new(name, value)
    end

    # A full document (not a fragment) whose `<title>` contains `title`.
    def render_page(title : String) : Expectations::RenderPage
      Expectations::RenderPage.new(title)
    end

    # A row of `schema` matching the typed `where` conditions, read through
    # the handle (the example's connection) the expectation is made on. A
    # macro, so an unknown or mistyped field fails compilation at the caller.
    macro have_row(schema, **conditions)
      %conditions = {{ conditions.empty? ? "NamedTuple.new".id : conditions }}
      ::Corretto::Expectations::HaveRow.new({{schema}}, {{schema}}.query.where(**%conditions), %conditions)
    end
  end
end
