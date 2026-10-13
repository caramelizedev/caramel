module Caramel
  # A type that a contract field may declare, bound from *W*: `String`, `Int32`, `Int64`,
  # `Float64`, `Bool` or `Time`. The field reads *W* with its grammar, then calls
  # `T.from_field(raw : W, & : String ->) : T?`, which returns the value, or yields a
  # message for the field's errors and returns nil (ADR 0034).
  module FieldValue(W)
  end
end
