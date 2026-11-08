module Caramel::Frappe
  # What Frappé's text output asks of the terminal it writes to.
  module Terminal
    # Whether to colour *io*: a terminal, NO_COLOR unset or empty
    # (https://no-color.org), and TERM not dumb.
    def self.color?(io : IO, environment : ENV.class | Hash(String, String) = ENV) : Bool
      return false unless io.tty?
      return false unless environment["NO_COLOR"]?.to_s.empty?
      environment["TERM"]? != "dumb"
    end

    def self.bold(text : String, color : Bool) : String
      color ? "\e[1m#{text}\e[0m" : text
    end

    # *text* in lines of at most *width* characters, broken at spaces.
    def self.wrap(text : String, width : Int32) : Array(String)
      lines = [] of String
      text.split.each do |piece|
        last = lines.last?
        if last && last.size + 1 + piece.size <= width
          lines[-1] = "#{last} #{piece}"
        else
          lines << piece
        end
      end
      lines
    end
  end
end
