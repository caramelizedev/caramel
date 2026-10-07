module Caramel::Crema
  # A statement written with its bind values, to paste into psql. The values are PostgreSQL
  # literals built where their types are still known (`Literal.of`), and substituted in one
  # pass so `$1` can never match inside `$10`.
  module SqlCopy
    # A placeholder, or text that may hold something that looks like one and must stay as it
    # is: a quoted string (an `E'..'` string honours backslash escapes) or identifier, a
    # comment, a dollar-quoted body.
    TOKEN = /
      (?<![A-Za-z0-9_$])[eE]'(?:[^'\\]++|\\.|'')*+'   # an escape string
      | '(?:[^']++|'')*+'          # a string
      | "(?:[^"]++|"")*+"          # an identifier
      | --[^\n]*+                  # a line comment
      | \/\*.*?\*\/                # a block comment
      | (?<![A-Za-z0-9_$])\$\$.*?\$\$   # a dollar-quoted body
      | (?<![A-Za-z0-9_$])\$(?<tag>[A-Za-z_]\w*)\$.*?\$\k<tag>\$
      | (?<![A-Za-z0-9_$])\$(?<n>\d+)                # a placeholder
    /mx

    # Longest literal kept; a longer value is left as its `$n`.
    MAX_LITERAL = 2000

    # *sql* with each `$n` replaced by `literals[n - 1]`. A placeholder with no literal, or
    # whose literal is empty (too long to keep), stays as it is.
    def self.fill(sql : String, literals : Array(String)?) : String
      return sql if literals.nil? || literals.empty?

      sql.gsub(TOKEN) do |token, match|
        number = match["n"]?.try(&.to_i?) || 0
        value = (1..literals.size).includes?(number) ? literals[number - 1] : ""
        value.empty? ? token : value
      end
    end

    # Whether *filled* still has a placeholder outside a quoted string.
    def self.unfilled?(filled : String) : Bool
      filled.scan(TOKEN).any?(&.["n"]?)
    end

    # A quoted string literal; quotes are doubled and nothing else needs escaping with
    # standard_conforming_strings on, which is PostgreSQL's default.
    def self.quote(text : String) : String
      "'#{text.gsub('\'', "''")}'"
    end
  end

  module Literal
    # The PostgreSQL literal for a bind, or "" when it is too long to keep.
    def self.of(value) : String
      text = case value
             when Nil   then "NULL"
             when Bool  then value.to_s
             when Int   then value.to_s
             when Float then value.finite? ? value.to_s : SqlCopy.quote(value.to_s)
             when Time  then SqlCopy.quote(value.to_utc.to_rfc3339(fraction_digits: 6))
             when Bytes then SqlCopy.quote("\\x#{value.hexstring}")
             when Array then array(value)
             else            SqlCopy.quote(value.to_s)
             end
      text.bytesize > SqlCopy::MAX_LITERAL ? "" : text
    end

    # `ARRAY[1,2]`, or `'{}'` for an empty array, which has no element type to infer.
    private def self.array(values : Array) : String
      return "'{}'" if values.empty?

      parts = values.map { |item| of(item) }
      return "" if parts.any?(&.empty?)

      "ARRAY[#{parts.join(',')}]"
    end
  end
end
