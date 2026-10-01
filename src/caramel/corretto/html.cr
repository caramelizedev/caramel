require "./html/comparison"

module Corretto::Expectations
  class HaveHTML
    @observed = 0
    @detail = ""
    @excerpt = ""

    def initialize(@pattern : HTML::Pattern, @within : String? = nil,
                   @count : Int32? = nil, @strict : Bool = false)
      raise ArgumentError.new("HTML count must be nonnegative") if @count.try(&.<(0))
    end

    def match(response : Caramel::Response) : Bool
      match(response.body)
    end

    def match(source : String) : Bool
      HTML::Document.open(source) do |document|
        candidates = candidates(document)
        comparison = HTML::Comparison.new(@strict)
        @observed = 0
        @detail = "No <#{@pattern.tag}> in the selected scope"
        @excerpt = source[0, 800]
        candidates.each do |node|
          next unless node.tag_name.downcase == @pattern.tag
          @excerpt = node.to_html[0, 800] if @observed.zero?
          if comparison.matches?(@pattern, node)
            @observed += 1
          else
            @detail = comparison.mismatch.to_s
          end
        end
        count = @count
        if count && @observed > 0
          @detail = "Expected exactly #{count} matching roots"
        end
        count ? @observed == count : @observed > 0
      end
    end

    def failure_message(actual) : String
      "Expected #{description}; found #{@observed}\n#{@detail[0, 800]}\nHTML: #{@excerpt}"
    end

    def negative_failure_message(actual) : String
      "Expected not #{description}; found #{@observed}\nHTML: #{@excerpt}"
    end

    private def description : String
      number = @count ? "#{@count} matches for" : "HTML matching"
      scope = @within ? " within #{@within.inspect}" : ""
      "#{number} #{@pattern.description}#{scope}"
    end

    private def candidates(document) : Array(Lexbor::Node)
      scope = @within
      return document.elements unless scope
      selected = document.select(scope)
      raise ArgumentError.new("HTML scope #{scope.inspect} matched no elements") if selected.empty?
      selected.flat_map(&.scope.to_a).reject do |node|
        node.is_text? || node.is_comment?
      end.uniq!(&.element)
    end
  end
end
