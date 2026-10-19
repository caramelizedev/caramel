module Ameba::Rule::Caramel
  # Reports `File` and `Dir` readers called with `__DIR__` (ADR 0032).
  #
  # A release artifact holds no source tree, so `__DIR__` names a path inside
  # the build container and the read fails only in production.
  #
  # ```
  # File.read("#{__DIR__}/a.css")   # reported
  # {{ read_file("#{__DIR__}/a") }} # not reported
  # File.read(path)                 # not reported
  # ```
  class SourceTreeRead < Base
    properties do
      description "Disallows run-time reads of paths built from __DIR__ (ADR 0032)"
    end

    MSG = "`__DIR__` names the build container in a release artifact, which holds no " \
          "source tree; embed the file with `{{ read_file(...) }}` or serve it from `public/`"

    READERS = {
      "File" => %w[read read_lines open new each_line exists? file? info],
      "Dir"  => %w[glob children each_child entries exists?],
    }

    def test(source, node : Crystal::Call)
      names = READERS[reader_class(node.obj)]?
      return unless names && names.includes?(node.name)

      finder = DirFinder.new(source)
      node.args.each(&.accept(finder))
      issue_for(node, MSG) if finder.found?
    end

    private def reader_class(receiver : Crystal::ASTNode?) : String
      return "" unless receiver.is_a?(Crystal::Path) && receiver.names.size == 1

      receiver.names.first
    end

    # :nodoc:
    class DirFinder < Crystal::Visitor
      include AST::Util

      getter? found = false

      def initialize(@source : Source)
      end

      def visit(node : Crystal::StringLiteral)
        @found = true if magic_dir?(node)
        true
      end

      # The parser expands `__DIR__` and folds an interpolation of it into one
      # literal, so the literal's source text is what names it.
      private def magic_dir?(node : Crystal::StringLiteral) : Bool
        node_source(node, @source.lines).try(&.includes?("__DIR__")) || false
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
