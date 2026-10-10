# The errors SweetTalk raises, and a glossary entry.
module SweetTalk
  # A domain rule said no. It ends the command, and the command's transaction rolls back.
  class Refusal < Exception
  end

  # A command, a factory, a handler or a service reached a second aggregate in one
  # transaction.
  class Boundary < Exception
  end

  # A record that does not exist.
  class Missing < Exception
  end

  # One entry of the ubiquitous language.
  record Term, kind : String, name : String, context : String, means : String
end
