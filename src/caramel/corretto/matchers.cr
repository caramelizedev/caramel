require "./html"

module Corretto
  # Expectations for `should`/`should_not`; `Corretto::Matchers` builds them.
  # Failure messages show the relevant part of the response.
  module Expectations
    def self.excerpt(response : Caramel::Response) : String
      body = response.body.size > 800 ? "#{response.body[0, 800]}…" : response.body
      headers = response.headers.compact_map do |name, values|
        "  #{name}: #{values.join(", ")}" unless name.in?("Content-Security-Policy", "Set-Cookie")
      end
      shown = body.empty? ? "(empty)" : body
      "Response status #{response.status}\n#{headers.join('\n')}\n  Body: #{shown}"
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

    class RenderPartial
      @found = "none"
      @detail = ""
      @excerpt = ""

      def initialize(@target : String, @swap : String?, @pattern : HTML::Pattern? = nil)
      end

      def match(response : Caramel::Response) : Bool
        HTML::Document.open(response.body) do |document|
          partials = document.select("hx-partial")
          @found = partials.join(", ") do |node|
            "#{node["hx-target"]?} (#{node["hx-swap"]?})"
          end
          @found = "none" if @found.empty?
          @detail = ""
          @excerpt = ""
          partials.any? do |node|
            next false unless node["hx-target"]? == @target
            next false unless @swap.nil? || node["hx-swap"]? == @swap
            @excerpt = node.to_html[0, 800]
            content_matches?(node)
          end
        end
      end

      def failure_message(response : Caramel::Response) : String
        "Expected an <hx-partial> for #{description}; found #{@found[0, 800]}\n" \
        "#{@detail[0, 800]}#{excerpt(response)}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no <hx-partial> for #{description}\n#{excerpt(response)}"
      end

      private def excerpt(response) : String
        return Expectations.excerpt(response) if @excerpt.empty?
        "Response status #{response.status}\nHTML: #{@excerpt}"
      end

      private def description : String
        target = @swap ? "#{@target} swapped with #{@swap}" : @target
        pattern = @pattern
        pattern ? "#{target} containing HTML matching #{pattern.summary[0, 500]}" : target
      end

      private def content_matches?(node) : Bool
        pattern = @pattern
        return true unless pattern
        comparison = HTML::Comparison.new
        found = node.scope.any? do |child|
          next false if child.is_text? || child.is_comment?
          next false unless child.tag_name.downcase == pattern.tag
          comparison.matches?(pattern, child)
        end
        @detail = "#{comparison.mismatch || pattern.description}\n" unless found
        found
      end
    end

    struct RedirectTo
      def initialize(@path : String)
      end

      def match(response : Caramel::Response) : Bool
        redirect = (300..399).includes?(response.status)
        (redirect && response.headers["Location"]? == @path) ||
          response.headers["HX-Location"]? == @path
      end

      def failure_message(response : Caramel::Response) : String
        excerpt = Expectations.excerpt(response)
        "Expected a redirect (Location or HX-Location) to #{@path}\n#{excerpt}"
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

    class RenderPage
      @found : String? = nil

      def initialize(@title : String)
      end

      def match(response : Caramel::Response) : Bool
        HTML::Document.open(response.body) do |document|
          @found = document.select("title").first?.try(&.inner_text)
          document.full_page? && (@found.try(&.includes?(@title)) || false)
        end
      end

      def failure_message(response : Caramel::Response) : String
        got = @found.try(&.inspect) || "no <title>"
        excerpt = Expectations.excerpt(response)
        "Expected a full HTML page titled #{@title.inspect}; got #{got}\n#{excerpt}"
      end

      def negative_failure_message(response : Caramel::Response) : String
        "Expected no full HTML page titled #{@title.inspect}\n#{Expectations.excerpt(response)}"
      end
    end

    struct HaveRow(T, Q, C)
      def initialize(@schema : T.class, @query : Q, @conditions : C)
      end

      def match(db : SugarORM::Handle) : Bool
        @query.exists?(db)
      end

      def failure_message(db : SugarORM::Handle) : String
        total = T.query.count(db)
        "Expected #{T} to have a row where #{description}; none matched among #{total} rows"
      end

      def negative_failure_message(db : SugarORM::Handle) : String
        "Expected #{T} to have no row where #{description}; #{@query.count(db)} matched"
      end

      private def description : String
        return "(any)" if @conditions.empty?

        @conditions.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
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

    # Requirements recorded with Blueprint's element vocabulary.
    def have_html(*, within : String? = nil, count : Int32? = nil, strict : Bool = false, &)
      pattern = HTML::PatternBuilder.build { |builder| with builder yield }
      Expectations::HaveHTML.new(pattern, within, count, strict)
    end

    def render_partial(target : String, swap : String? = nil, &)
      pattern = HTML::PatternBuilder.build { |builder| with builder yield }
      Expectations::RenderPartial.new(target, swap, pattern)
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
      ::Corretto::Expectations::HaveRow.new(
        {{ schema }},
        {{ schema }}.query.where(**%conditions),
        %conditions,
      )
    end
  end
end
