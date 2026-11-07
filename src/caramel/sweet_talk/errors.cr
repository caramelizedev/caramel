# The errors SweetTalk raises, and a glossary entry.
module SweetTalk
  # A domain rule said no. It ends the command, and the command's transaction rolls back.
  # An action that does not rescue it answers 422 (ADR 0034), under the field `on` names
  # when its contract has that field, else under `_base` (ADR 0058).
  class Refusal < Exception
    # The field the refusal is about, as `refuse "…", on: :quantity` names it, or nil.
    getter on : String?

    def initialize(message : String? = nil, on : Symbol? = nil)
      super(message)
      @on = on.try(&.to_s)
    end
  end

  # Refuses an `on:` of *word*, a `never` or an `always`, that is not a symbol. It runs as a
  # macro of its own so the error points at the author's line.
  macro __sweettalk_refusal_field(word, on)
    {% unless on.is_a?(NilLiteral) || on.is_a?(SymbolLiteral) %}
      {% on.raise "#{word.id} takes on: the field its refusal is about, as in on: :quantity, " +
                  "not #{on}" %}
    {% end %}
  end

  # A command, a factory, a handler or a service reached a second aggregate in one
  # transaction. It is a programming error, and an action answers it 500.
  class Boundary < Exception
  end

  # A record that does not exist; an action that does not rescue it answers 404.
  class Missing < Exception
  end

  # A list of entities read on an aggregate found with `entities: false`. It is a
  # programming error, and an action answers it 500.
  class Unloaded < Exception
  end

  # One entry of the ubiquitous language. *subdomain* is its context's `subdomain:`, as
  # "core", "supporting" or "generic", or nil when the context names none or is a kernel.
  record Term, kind : String, name : String, context : String, means : String,
    subdomain : String? = nil

  # What assures a requirement: the kind of declaration, `never`, `always`, `specification`
  # or `unit`, its sentence or meaning, and what holds it.
  record Assurance, kind : String, text : String, owner : String

  # One requirement id and every declaration that assures it, in the order they were found.
  record Requirement, id : String, assured_by : Array(Assurance)
end
