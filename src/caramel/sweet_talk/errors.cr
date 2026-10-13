# The errors SweetTalk raises, and a glossary entry.
module SweetTalk
  # A domain rule said no. It ends the command, and the command's transaction rolls back.
  # An action that does not rescue it answers 422 (ADR 0034).
  class Refusal < Exception
  end

  # A command, a factory, a handler or a service reached a second aggregate in one
  # transaction. It is a programming error, and an action answers it 500.
  class Boundary < Exception
  end

  # A record that does not exist; an action that does not rescue it answers 404.
  class Missing < Exception
  end

  # One entry of the ubiquitous language. *subdomain* is its context's `subdomain:`, as
  # "core", "supporting" or "generic", or nil when the context names none.
  record Term, kind : String, name : String, context : String, means : String,
    subdomain : String? = nil
end
