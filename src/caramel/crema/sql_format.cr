require "../html"
require "./sql_copy"

module Caramel::Crema
  # A statement as HTML for reading: one clause per line, keywords, numbers, strings and
  # placeholders coloured. A statement that already holds line breaks keeps its own layout.
  # Display only: what a copy button writes is the statement as it ran.
  module SqlFormat
    CLAUSES = %w[
      SELECT FROM WHERE HAVING LIMIT OFFSET RETURNING VALUES SET UNION EXCEPT INTERSECT
      JOIN INNER FULL CROSS NATURAL FOR WINDOW
    ]

    KEYWORDS = Set(String).new(CLAUSES + %w[
      INSERT INTO UPDATE DELETE AND OR NOT IN IS NULL AS ON BY ASC DESC NULLS FIRST LAST DISTINCT
      ALL ANY SOME CASE WHEN THEN ELSE END EXISTS BETWEEN LIKE ILIKE OUTER LEFT RIGHT USING WITH
      RECURSIVE CONFLICT DO NOTHING DEFAULT TRUE FALSE SKIP LOCKED SHARE NOWAIT OVER PARTITION
      FILTER WITHIN LATERAL ARRAY INTERVAL CAST GROUP ORDER
    ])

    JOIN_PREFIX = %w[LEFT RIGHT INNER FULL CROSS OUTER NATURAL]

    # Whitespace, a word, a number, or any other single character.
    PLAIN = /\s+|[A-Za-z_][A-Za-z0-9_$]*|\d+(?:\.\d+)?|./m

    enum Part
      Space
      Word
      Number
      Open
      Close
      Other
      Text
      Name
      Comment
      Placeholder
    end

    record Token, part : Part, text : String

    # One line of the layout; a *condition* line (AND, OR) is indented one step further.
    record Line, condition : Bool, tokens : Array(Token)

    def self.html(sql : String) : String
      String.build do |io|
        io << %(<code class="sql">)
        lines(sql).each { |line| line_html(io, line) }
        io << "</code>"
      end
    end

    private def self.lines(sql : String) : Array(Line)
      tokens = tokens(sql)
      own_layout = tokens.any? { |token| line_break?(token) }
      own_layout ? preserved(tokens) : Layout.new(tokens).lines
    end

    private def self.line_break?(token : Token) : Bool
      token.part.space? && token.text.includes?('\n')
    end

    private def self.tokens(sql : String) : Array(Token)
      sql = sql.strip
      tokens = [] of Token
      position = 0
      sql.scan(SqlCopy::TOKEN) do |match|
        start = match.byte_begin(0)
        plain_tokens(tokens, sql.byte_slice(position, start - position))
        tokens << protected_token(match)
        position = match.byte_end(0)
      end
      plain_tokens(tokens, sql.byte_slice(position))
      tokens
    end

    private def self.protected_token(match : Regex::MatchData) : Token
      text = match[0]
      return Token.new(Part::Placeholder, text) if match["n"]?
      return Token.new(Part::Comment, text) if text.starts_with?("--") || text.starts_with?("/*")
      return Token.new(Part::Name, text) if text.starts_with?('"')

      Token.new(Part::Text, text)
    end

    private def self.plain_tokens(tokens : Array(Token), gap : String) : Nil
      gap.scan(PLAIN) { |match| tokens << Token.new(plain_part(match[0]), match[0]) }
    end

    private def self.plain_part(text : String) : Part
      first = text[0]
      return Part::Space if first.whitespace?
      return Part::Word if first.ascii_letter? || first == '_'
      return Part::Number if first.ascii_number?
      return Part::Open if first == '('
      return Part::Close if first == ')'

      Part::Other
    end

    # The statement's own line breaks, with the indentation after each kept.
    private def self.preserved(tokens : Array(Token)) : Array(Line)
      lines = [Line.new(false, [] of Token)]
      tokens.each do |token|
        next lines.last.tokens << token unless line_break?(token)

        pieces = token.text.split('\n')
        (1...pieces.size).each { |index| lines << indented(pieces, index) }
      end
      lines
    end

    # The line that starts after the break before `pieces[index]`: only the last piece is
    # indentation, the others are whitespace before another break.
    private def self.indented(pieces : Array(String), index : Int32) : Line
      indent = pieces[index]
      last = index == pieces.size - 1
      Line.new(false, last && !indent.empty? ? [Token.new(Part::Space, indent)] : [] of Token)
    end

    private def self.line_html(io : IO, line : Line) : Nil
      io << (line.condition ? %(<span class="line cond">) : %(<span class="line">))
      io << ' ' if line.tokens.empty?
      line.tokens.each { |token| token_html(io, token) }
      io << "</span>"
    end

    private def self.token_html(io : IO, token : Token) : Nil
      case token.part
      when .word?        then word_html(io, token.text)
      when .number?      then wrapped(io, "num", token.text)
      when .text?        then wrapped(io, "str", token.text)
      when .comment?     then wrapped(io, "cm", token.text)
      when .placeholder? then placeholder_html(io, token.text)
      else                    io << HTML.escape(token.text)
      end
    end

    private def self.word_html(io : IO, text : String) : Nil
      return io << HTML.escape(text) unless KEYWORDS.includes?(text.upcase)

      wrapped(io, "kw", text)
    end

    private def self.placeholder_html(io : IO, text : String) : Nil
      io << %(<span class="ph" data-n=") << text[1..] << %(">) << HTML.escape(text) << "</span>"
    end

    private def self.wrapped(io : IO, kind : String, text : String) : Nil
      io << %(<span class=") << kind << %(">) << HTML.escape(text) << "</span>"
    end

    # Breaks tokens into lines, one clause each. Only a word outside parentheses starts a
    # line, so a subquery or a function call stays on its line.
    private class Layout
      def initialize(@tokens : Array(Token))
        @lines = [Line.new(false, [] of Token)]
        @depth = 0
        @previous = ""
        @between = false
        @first = true
      end

      def lines : Array(Line)
        @tokens.each_with_index { |token, index| add(token, index) }
        @lines
      end

      private def add(token : Token, index : Int32) : Nil
        case token.part
        when .open?  then @depth += 1
        when .close? then @depth = {@depth - 1, 0}.max
        when .space? then return add_space
        when .word?  then add_word(index)
        end
        @lines.last.tokens << token
      end

      private def add_space : Nil
        current = @lines.last.tokens
        current << Token.new(Part::Space, " ") unless current.empty?
      end

      private def add_word(index : Int32) : Nil
        word = @tokens[index].text.upcase
        start_line(index, word) if @depth == 0 && !@first
        @between = word == "BETWEEN" || (@between && word != "AND")
        @first = false
        @previous = word
      end

      private def start_line(index : Int32, word : String) : Nil
        return new_line(false) if clause?(index, word)
        return if word == "AND" && @between

        new_line(true) if word == "AND" || word == "OR"
      end

      private def new_line(condition : Bool) : Nil
        current = @lines.last.tokens
        while current.last?.try(&.part.space?)
          current.pop
        end
        @lines << Line.new(condition, [] of Token)
      end

      private def clause?(index : Int32, word : String) : Bool
        following = following(index)
        case word
        when "FROM"           then !{"DELETE", "DISTINCT"}.includes?(@previous)
        when "JOIN"           then !JOIN_PREFIX.includes?(@previous)
        when "LEFT", "RIGHT"  then !following.try(&.part.open?)
        when "GROUP", "ORDER" then word?(following, "BY")
        when "ON"             then word?(following, "CONFLICT")
        else                       CLAUSES.includes?(word)
        end
      end

      private def following(index : Int32) : Token?
        @tokens[(index + 1)..].find { |token| !token.part.space? }
      end

      private def word?(token : Token?, text : String) : Bool
        return false unless token

        token.part.word? && token.text.upcase == text
      end
    end
  end
end
