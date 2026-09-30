module Caramel::Frappe
  # Machine-Readable Diagnostic Protocol (RFC-0005 §2.3, Mode B): plain
  # lines with no ANSI. Each diagnostic is an `ERR` line followed by one
  # `KEY: value` field per line.
  module MRDP
    CODES = %w[
      CONTRACT_MISMATCH N_PLUS_ONE UNDEFINED_METHOD UNDEFINED_CONSTANT NO_OVERLOAD
      SYNTAX COMPILE USAGE LINT_<RULE> DIFF_HALT
    ]

    GRAMMAR = <<-TEXT
      MRDP (with --agent, or whenever stdout is not a TTY)
      ERR <CODE>[:<HTTP status>] at <file>:<line>:<col> | <subject>
      NODE: <kind of source node the error concerns>
      MISSING: <name>:<Type>
      MSG: <message>
      FIX: <remediation>
      PATCH: INSERT "<text>" AT <line>:<col>  # insert <text> as a new line \
        before <line> of the ERR file, indented to <col>
      PATCH: INSERT "<text>" AFTER <line>:<col>  # insert <text> into <line> \
        of the ERR file after column <col>
      SYNTAX: frappe <syntax>
      SUGGEST: <nearest valid token>
      OK <command> <summary>
      CODES: #{CODES.join(" ")}
      EXIT: 0 when no ERR line is printed; 1 otherwise
      TEXT

    def self.write(io : IO,
                   code : String,
                   at : String,
                   fields : Enumerable(Tuple(String, String))) : Nil
      io << "ERR " << code << " at " << at << '\n'
      fields.each { |key, value| io << key << ": " << flat(value) << '\n' }
    end

    # Values are single-line: a line break would start a new field.
    def self.flat(text : String) : String
      text.strip.gsub(/\s*\n\s*/, " ")
    end

    # Selects Mode B: `--agent` wins, then `--human`, then stdout's TTY state.
    def self.agent?(arguments : Enumerable(String), output : IO) : Bool
      return true if arguments.includes?("--agent")
      return false if arguments.includes?("--human")
      !output.tty?
    end
  end
end
