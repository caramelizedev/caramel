require "compiler/crystal/syntax"

module Caramel::Frappe
  # `crystal tool expand` reports only the nodes the compiler expanded. A macro
  # call written inside another macro's block, such as `field` inside
  # `contract do … end`, is re-emitted as text by the outer macro and is never
  # expanded itself, so `frappe expand` falls back to the call whose block
  # encloses the position and keeps the steps that consume the requested call.
  module ExpandFallback
    record Enclosing, name : String, line : Int32, column : Int32

    NOT_FOUND = "no expansion found"

    # Calls whose block contains the position, innermost first. A call whose
    # own name sits at the position is left out: the first attempt covered it.
    def self.enclosing(source : String, line : Int32, column : Int32) : Array(Enclosing)
      visitor = Finder.new({line, column})
      Crystal::Parser.parse(source).accept(visitor)
      visitor.found.sort_by! { |entry| {-entry[0][0], -entry[0][1]} }.map { |entry| entry[1] }
    rescue Crystal::SyntaxException
      [] of Enclosing
    end

    # The call `crystal tool expand` named when it found nothing.
    def self.unexpanded_call(output : String) : String?
      match = output.match(/\Ano expansion found: (.+) may not be a macro\n?\z/m)
      match.try(&.[1])
    end

    def self.found?(output : String) : Bool
      !output.starts_with?(NOT_FOUND)
    end

    # Keeps, in each expansion, the steps up to the first one that no longer
    # contains `call`, the step that expanded it. Expansions that never expand
    # the call are dropped; nil when none does. Without a call, the output is
    # kept whole.
    def self.trim(output : String, call : String?) : String?
      return output unless call
      needle = squeeze(call)
      lines = output.lines(chomp: false)
      groups = [] of Array(String)
      lines.each do |line|
        if line.matches?(/\Aexpansion \d+:$/)
          groups << [line]
        elsif group = groups.last?
          group << line
        end
      end
      kept = groups.compact_map { |group| consuming(group, needle) }
      return if kept.empty?
      count = kept.size
      heading = "#{count} #{count == 1 ? "expansion" : "expansions"} found\n"
      kept.each_with_index.reduce(heading) do |text, (group, index)|
        text + group.sub(/\Aexpansion \d+:/, "expansion #{index + 1}:")
      end
    end

    # A step is its header lines, several when one expansion serves
    # several calls of a macro, then the body they share.
    private def self.consuming(group : Array(String), needle : String) : String?
      steps = [] of Array(String)
      group.each do |line|
        if !line.starts_with?("# expand ")
          steps.last?.try(&.<<(line))
        elsif (step = steps.last?) && step.all?(&.starts_with?("# expand "))
          step << line
        else
          steps << [line]
        end
      end
      first = group.index(&.starts_with?("# expand "))
      return unless first
      head = group[0...first]
      previous = occurrences(squeeze(head.join), needle)
      return if previous.zero?
      steps.each_with_index do |step, index|
        current = occurrences(squeeze(step.join), needle)
        if current < previous
          kept = steps[0..index].flatten
          return (head + kept).join
        end
        previous = current
      end
      nil
    end

    private def self.squeeze(text : String) : String
      text.gsub(/\s+/, " ")
    end

    private def self.occurrences(text : String, needle : String) : Int32
      count = 0
      offset = 0
      while found = text.index(needle, offset)
        count += 1
        offset = found + needle.size
      end
      count
    end

    private class Finder < Crystal::Visitor
      getter found = [] of {Tuple(Int32, Int32), Enclosing}

      def initialize(@target : Tuple(Int32, Int32))
      end

      def visit(node : Crystal::Call)
        block = node.block
        start = block.try(&.location)
        finish = block.try(&.end_location)
        if block && start && finish && inside?(start, finish) && !own_name?(node)
          position = node.obj.is_a?(Crystal::Path) ? node.location : node.name_location
          position ||= node.location
          if position
            entry = Enclosing.new(node.name, position.line_number, position.column_number)
            @found << { {start.line_number, start.column_number}, entry }
          end
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def inside?(start : Crystal::Location, finish : Crystal::Location) : Bool
        {start.line_number, start.column_number} <= @target &&
          @target <= {finish.line_number, finish.column_number}
      end

      private def own_name?(node : Crystal::Call) : Bool
        start = node.obj.is_a?(Crystal::Path) ? node.location : node.name_location
        finish = node.name_end_location
        return false unless start && finish
        {start.line_number, start.column_number} <= @target &&
          @target <= {finish.line_number, finish.column_number}
      end
    end
  end
end
