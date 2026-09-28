require "./mrdp"

module Caramel::Frappe
  # One compiler diagnostic (RFC-0005 §2.3), rendered as MRDP for agents or
  # in the RFC-0008 §2.6 typography for people.
  class Diagnostic
    SUMMARIES = {
      "CONTRACT_MISMATCH"  => "A route parameter must bind to a field of its action's contract.",
      "N_PLUS_ONE"         => "Accessing un-preloaded relationships triggers runtime N+1 queries.",
      "UNDEFINED_METHOD"   => "The receiver's type defines no such method or local variable.",
      "UNDEFINED_CONSTANT" => "No type or constant has this name here.",
      "NO_OVERLOAD"        => "No method signature accepts these arguments.",
      "SYNTAX"             => "The source does not parse.",
      "COMPILE"            => "The program does not compile.",
    }

    getter code : String
    getter status : Int32?
    getter file : String
    getter line : Int32
    getter column : Int32
    getter width : Int32
    getter message : String
    getter details : Array(String)
    getter remediation : String?
    getter node : String?
    getter missing : String?
    getter patch : String?
    getter source : String?

    def initialize(@code, @file, @line, @column, @message, *, @width = 1, @details = [] of String, @remediation = nil,
                   @status = nil, @node = nil, @missing = nil, @patch = nil, @source = nil)
    end

    def location : String
      @line > 0 ? "#{@file}:#{@line}:#{@column}" : @file
    end

    # Mode B. A MISSING line states the problem, so it replaces MSG; a PATCH
    # replaces FIX.
    def to_mrdp(io : IO) : Nil
      fields = [] of {String, String}
      @node.try { |node| fields << {"NODE", node} }
      if missing = @missing
        fields << {"MISSING", missing}
      else
        fields << {"MSG", @message}
      end
      if patch = @patch
        fields << {"PATCH", patch}
      elsif remediation = @remediation
        fields << {"FIX", remediation}
      end
      MRDP.write(io, @status ? "#{@code}:#{@status}" : @code, location, fields)
    end

    # Mode A (RFC-0008 §2.6): the source line boxed with its file and line, a
    # caret under the column, then the remediation. ANSI only when `color`.
    def render(io : IO, color : Bool) : Nil
      paint = ->(text : String, style : String) { color ? "\e[#{style}m#{text}\e[0m" : text }
      bar = paint.call("│", "2")
      io << "  " << paint.call("╭─[ ", "2") << (@line > 0 ? "#{@file}:#{@line}" : @file) << paint.call(" ]", "2") << '\n'
      io << "  " << bar << '\n'
      if (source = @source) && @line > 0
        number = @line.to_s
        text = source.gsub('\t', ' ')
        start = (@column - 1).clamp(0, text.size)
        carets = "^" * @width.clamp(1, Math.max(1, text.size - start))
        io << "  " << bar << "  " << number << ' ' << bar << ' ' << text << '\n'
        io << "  " << bar << "  " << " " * number.size << ' ' << bar << ' ' << " " * start << paint.call(carets, "1;31") << ' ' << paint.call(@message, "1") << '\n'
      else
        io << "  " << bar << "  " << paint.call(@message, "1") << '\n'
      end
      io << "  " << bar << '\n'
      io << "  " << paint.call("╰─", "2") << ' ' << paint.call(SUMMARIES[@code], "33") << '\n'
      @details.each { |detail| io << "     " << detail << '\n' }
      if remediation = @remediation
        io << "\n     " << paint.call("Remediation:", "1;32") << '\n'
        remediation.each_line { |advice| io << "     " << advice.sub(/\A[a-z]/, &.upcase) << '\n' }
      end
    end
  end

  # Parses `crystal build --no-codegen` output. Without --error-trace the
  # compiler prints only the last frame: an `In`/`Code in FILE:LINE:COL`
  # header, the source line with a caret, and `Error: ` followed by the
  # message. Caramel's macro errors add `--> FILE:LINE:COL` and
  # `Remediation:` lines; the router adds `Contract: FILE:LINE:COL`.
  module Diagnostics
    FRAME    = /\A(?:In|Code in) (.+):(\d+):(\d+)\z/
    ARROW    = /\A\s*--> (.+):(\d+):(\d+)\s*\z/
    CONTRACT = /\AContract: (.+):(\d+):(\d+)\z/
    SENTINEL = /NotLoaded\(NamedTuple\("(.+?)": Nil\)\)/

    # `root` is the compiler's working directory; paths under it are shown
    # relative to it. `entrypoint` locates errors that name no file.
    # ameba:disable Metrics/CyclomaticComplexity -- one branch per compiler output form
    def self.parse(output : String, root : String, entrypoint : String) : Array(Diagnostic)
      lines = output.gsub(/\e\[[0-9;]*m/, "").lines
      error = lines.rindex(&.starts_with?("Error: "))
      unless error
        message = lines.reverse.find { |line| !line.strip.empty? }.try(&.strip) || "the compiler failed without a message"
        return [Diagnostic.new("COMPILE", entrypoint, 0, 0, message)]
      end
      file, line, column, width = entrypoint, 0, 0, 1
      if frame = (0...error).reverse_each.find { |index| lines[index].matches?(FRAME) }
        match = lines[frame].match!(FRAME)
        file, line, column = relative(match[1], root), match[2].to_i, match[3].to_i
        caret = lines[(frame + 1)...error].find(&.matches?(/\A\s*\^[-~]*\s*\z/))
        width = caret.strip.size if caret
      end
      block = [lines[error].lchop("Error: ")] + lines[(error + 1)..]
      while block.first?.try(&.strip.empty?)
        block.shift
      end
      while block.last?.try(&.strip.empty?)
        block.pop
      end
      text = block.join('\n')
      unframed = lines.none?(&.starts_with?("Showing last frame"))

      if text.includes?("ROUTE CONTRACT MISMATCH") || text.includes?("ROUTE CONTRACT TYPE MISMATCH")
        return [contract_mismatch(block, root, file, line, column)]
      end
      if sentinel = text.match(SENTINEL)
        return [n_plus_one(sentinel[1], root, file, line, column, width)]
      end

      details = [] of String
      remediation = nil
      echo = false
      message = nil
      block.each do |entry|
        stripped = entry.strip
        if match = entry.match(ARROW)
          file, line, column, width = relative(match[1], root), match[2].to_i, match[3].to_i, 1
          echo = true
          next
        end
        # A `-->` line may be followed by the declaration it points at.
        next if echo && entry.starts_with?("      ")
        echo = false
        next if stripped.empty?
        if stripped.starts_with?("Remediation:")
          remediation = stripped.lchop("Remediation:").strip
        elsif message.nil?
          message = stripped.lchop("❌ ").lchop("Compile Error: ")
        elsif stripped.starts_with?("Did you mean") && remediation.nil?
          remediation = stripped
        else
          details << stripped
        end
      end
      message ||= "the compiler reported an error"
      # `❌ DUPLICATE ROUTE` headers carry the explanation on the next line.
      if message.matches?(/\A[A-Z ]+\z/) && (explanation = details.shift?)
        message = "#{message.capitalize}: #{explanation}"
      end
      code = case message
             when /\Aundefined constant /                                                                         then "UNDEFINED_CONSTANT"
             when /\Aundefined (?:local variable or )?method /                                                    then "UNDEFINED_METHOD"
             when /\A(?:no overload matches|expected argument #\d+|no parameter named|wrong number of arguments)/ then "NO_OVERLOAD"
             when /\A(?:expecting |unexpected |unterminated |invalid )/
               # Parser errors are the only ones printed without the frame notice.
               unframed ? "SYNTAX" : "COMPILE"
             else "COMPILE"
             end
      [Diagnostic.new(code, file, line, column, message, width: width, details: details, remediation: remediation, source: source(root, file, line))]
    end

    # The router's message names the route, its location (`-->`) and the
    # contract block (`Contract:`), which is where the fix goes.
    # ameba:disable Metrics/CyclomaticComplexity -- both router mismatch forms
    private def self.contract_mismatch(block : Array(String), root : String, file : String, line : Int32, column : Int32) : Diagnostic
      route = first(block, /\ARoute: '([^']+)'/).try(&.[1]) || "?"
      remediation = first(block, /\ARemediation: (.+)\z/).try(&.[1])
      declaration = remediation.try(&.match(/`(field (\w+) : (\w+))`/))
      where = first(block, ARROW)
      contract = first(block, CONTRACT)
      route_at = where ? "#{relative(where[1], root)}:#{where[2]}:#{where[3]}" : "#{file}:#{line}:#{column}"
      if contract
        file, line, column = relative(contract[1], root), contract[2].to_i, contract[3].to_i
      elsif where
        file, line, column = relative(where[1], root), where[2].to_i, where[3].to_i
      end
      source = source(root, file, line)
      width = source && source[(column - 1)..]?.try(&.starts_with?("contract")) ? "contract".size : 1
      if missing = first(block, /\AAction: '([^']+)' is missing 'field (\w+) : Type'\z/)
        # `contract do` must end its line for the next line to be inside the block.
        patch = if contract && declaration && source.try(&.matches?(/\bdo\s*\z/))
                  %(INSERT "#{declaration[1]}" AT #{line + 1}:#{column + 2})
                end
        Diagnostic.new("CONTRACT_MISMATCH", file, line, column, "#{missing[1]} is missing 'field #{missing[2]} : Type' for route '#{route}'",
          width: width, status: 422, node: "RequestContract", missing: declaration ? "#{declaration[2]}:#{declaration[3]}" : missing[2],
          details: ["Route '#{route}' is declared at #{route_at}"], remediation: remediation, patch: patch, source: source)
      else
        binding = first(block, /\ARoute: '[^']+' (parameter .+)\z/).try(&.[1]) || "parameter binds to an unsupported field"
        rule = first(block, /\A(Path parameters .+)\z/).try(&.[1])
        details = [rule, "Route '#{route}' is declared at #{route_at}"].compact
        Diagnostic.new("CONTRACT_MISMATCH", file, line, column, "Route '#{route}' #{binding}", width: width, status: 422,
          node: "RequestContract", details: details, remediation: remediation, source: source)
      end
    end

    private def self.first(lines : Array(String), pattern : Regex) : Regex::MatchData?
      lines.each { |line| (match = line.match(pattern)) && return match }
      nil
    end

    # SugarORM's sentinel type name reads "Association 'x' of T was not
    # preloaded; … Remediation: add .preload(:x) to the query …".
    private def self.n_plus_one(text : String, root : String, file : String, line : Int32, column : Int32, width : Int32) : Diagnostic
      statement, _, remediation = text.partition(" Remediation: ")
      message = statement.partition("; ").first.rstrip('.') + "."
      association = remediation.match(/\.preload\(:(\w+)\)/).try(&.[1])
      source = source(root, file, line)
      patch = nil
      if association && source
        before = source[0, Math.max(0, column - 1)]
        if (access = before.rindex(".#{association}")) && !before[access + 1 + association.size]?.try(&.alphanumeric?)
          column, width = access + 2, association.size
          if query = source[0, access].rindex(/\.query(?![\w(])/)
            patch = %(INSERT ".preload(:#{association})" AFTER #{line}:#{query + ".query".size})
          end
        end
      end
      Diagnostic.new("N_PLUS_ONE", file, line, column, message, width: width, remediation: remediation.empty? ? nil : remediation,
        patch: patch, source: source)
    end

    private def self.relative(path : String, root : String) : String
      path = Path.new(path).normalize.to_s if path.starts_with?('/')
      path.starts_with?(root + "/") ? path[(root.size + 1)..] : path
    end

    private def self.source(root : String, file : String, line : Int32) : String?
      return unless line > 0
      path = File.expand_path(file, root)
      return unless File.file?(path)
      number = 0
      File.each_line(path) do |text|
        number += 1
        return text if number == line
      end
      nil
    rescue File::Error
      nil
    end
  end
end
