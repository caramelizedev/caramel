module Ameba::Rule::Caramel
  # Reports leftover `dump(value)` and `Caramel.dump(value)` calls (ADR 0027).
  #
  # `dump` prints a value and records it in the development inspector; it is a
  # no-op in production, so a forgotten call is harmless but noisy.
  #
  # ```
  # dump(book)         # reported
  # Caramel.dump(book) # reported
  # book.dump          # not reported
  # ```
  class Dump < Base
    properties do
      description "Disallows leftover dump calls (ADR 0027)"
    end

    MSG = "`dump` is a development aid; remove it before committing"

    def test(source, node : Crystal::Call)
      return unless node.name == "dump"
      return unless caramel_or_implicit?(node.obj)

      issue_for(node, MSG)
    end

    private def caramel_or_implicit?(receiver : Crystal::ASTNode?) : Bool
      return true if receiver.nil?

      receiver.is_a?(Crystal::Path) && receiver.names == ["Caramel"]
    end
  end
end
