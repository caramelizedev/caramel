# Ameba cannot infer the receiver supplied by Crystal's `with ... yield`.
# Recognize only paragraph calls inside Corretto's expectation blocks;
# ordinary p, pp and p! calls still use Ameba's original rule.
module Ameba::Rule::Lint
  class DebugCalls
    def test(source : Source)
      source.ast.accept(HTMLExpectationVisitor.new(self, source))
    end
  end

  # :nodoc:
  class HTMLExpectationVisitor < Crystal::Visitor
    @html_depth = 0

    def initialize(@rule : DebugCalls | Style::MultilineCurlyBlock, @source : Source)
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    def visit(node : Crystal::Call)
      paragraph = @html_depth > 0 && node.name == "p" && node.obj.nil? && node.args.empty?
      if rule = @rule.as?(DebugCalls)
        rule.test(@source, node) unless paragraph
      end
      return true unless node.name.in?("have_html", "render_partial") && node.block
      node.obj.try(&.accept(self))
      node.args.each(&.accept(self))
      node.named_args.try(&.each(&.accept(self)))
      @html_depth += 1
      node.block.try(&.accept(self))
      @html_depth -= 1
      false
    end

    def visit(node : Crystal::Block)
      if rule = @rule.as?(Style::MultilineCurlyBlock)
        rule.test(@source, node) if @html_depth.zero?
      end
      true
    end
  end
end

module Ameba::Rule::Style
  class MultilineCurlyBlock
    def test(source : Source)
      source.ast.accept(Lint::HTMLExpectationVisitor.new(self, source))
    end
  end
end
