module Caramel
  # Helpers for values written into HTML text and quoted attribute contexts.
  #
  # This intentionally does not attempt to validate or sanitize JavaScript,
  # CSS, URL, or other non-HTML contexts. Callers should use the appropriate
  # policy for those contexts before rendering a value.
  module HTML
    # A value that a caller has explicitly marked as trusted HTML.
    struct Safe
      getter value : String

      def initialize(@value : String)
      end

      def to_s : String
        @value
      end

      def to_s(io : IO) : Nil
        io << @value
      end
    end

    # Escapes the five characters with syntax significance in HTML text and
    # quoted attributes.
    def self.escape(value : String) : String
      String.build(value.bytesize) do |io|
        value.each_char do |char|
          case char
          when '&'
            io << "&amp;"
          when '<'
            io << "&lt;"
          when '>'
            io << "&gt;"
          when '"'
            io << "&quot;"
          when '\''
            io << "&#39;"
          else
            io << char
          end
        end
      end
    end

    # Trusted output is emitted exactly as supplied. Construction of Safe is
    # deliberately explicit at the call site.
    def self.escape(value : Safe) : String
      value.value
    end

    # Render other Crystal values through their string representation before
    # applying the same HTML escaping rules.
    def self.escape(value) : String
      escape(value.to_s)
    end
  end
end
