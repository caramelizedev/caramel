require "./words"

module Caramel::Frappe
  # What keeps `frappe words`, the SweetTalk guide and the SweetTalk skill true to the
  # macros: each method returns the problems it finds, one sentence each, naming the file
  # and line to change. `scripts/check sweet-talk-compilation` compiles the examples and
  # `scripts/check website` reads the guide with `prose`; the specs read the rest.
  struct WordDrift
    # Keywords the prose uses that no word takes: `logged` reads `subject:`, `since:`,
    # `before:` and `limit:`, and `state:` is a key of `where:` in a query.
    OTHER_KEYWORDS = %w[before limit since state subject]

    # A summary is one line of the listing `frappe words` prints.
    SUMMARY_LIMIT = 100

    def initialize(@words : Words)
    end

    # The macros held to their tags: every word has its block, every parameter its option,
    # every usage line and example its word.
    def source : Array(String)
      problems = @words.notes.dup
      @words.untagged.each do |macro_|
        problems << "macro #{macro_.name} (#{macro_.location}) has no @word block: " \
                    "describe it in its doc comment, or make it a refusal that only raises"
      end
      @words.forms.each { |form| form(form, problems) }
      kinds(problems)
      declared(problems)
      problems
    end

    # The keywords and words a Markdown text uses, held to the macros. *guide* adds the
    # rule that the text names every word and every option.
    def prose(markdown : String, origin : String, guide : Bool = false) : Array(String)
      problems = [] of String
      snippets = WordDrift.snippets(markdown)
      snippets.each { |snippet| calls(snippet, origin, problems) }
      keywords(snippets, origin, problems)
      mentions(snippets, markdown, origin, problems) if guide
      problems
    end

    # The `@guide` ids that are no section of *markdown*, the guide's Markdown edition.
    def sections(markdown : String, origin : String) : Array(String)
      @words.forms.compact_map do |form|
        anchor = form.section.guide || next
        next if markdown.includes?("{##{anchor}}")
        "#{form.name} (#{form.location}): @guide #{anchor} is no section of #{origin}"
      end
    end

    # The Crystal in *markdown*: its fenced blocks without a language or in Crystal, and
    # each inline code span, with the line it is on.
    def self.snippets(markdown : String) : Array({String, Int32})
      found = [] of {String, Int32}
      fence = nil
      held = [] of String
      markdown.each_line.with_index(1) do |line, number|
        if line.starts_with?("```")
          if fence
            found << {held.join('\n'), number} if fence.empty? || fence == "crystal"
            fence = nil
            held.clear
          else
            fence = line[3..].strip
          end
        elsif fence
          held << line.chomp
        else
          line.scan(/`([^`]+)`/) { |match| found << {match[1], number} }
        end
      end
      found
    end

    private def form(form : Words::Form, problems : Array(String)) : Nil
      section = form.section
      name = "#{form.name} (#{form.location})"
      section.problems.each { |problem| problems << "#{name}: #{problem}" }
      problems << "#{name}: @word says kind #{section.kind.inspect}, not one of " \
                  "#{Words::KINDS.keys.join(", ")}" unless Words::KINDS.has_key?(section.kind)
      problems << "#{name}: @word has no summary" if section.summary.blank?
      if section.summary.size > SUMMARY_LIMIT
        problems << "#{name}: its summary is #{section.summary.size} characters: " \
                    "keep it to one line of at most #{SUMMARY_LIMIT}"
      end
      problems << "#{name}: has no @usage" if section.usage.try(&.blank?) != false
      problems << "#{name}: has no @guide section" if section.guide.try(&.blank?) != false
      unless section.where || Words::SCOPES.has_key?(form.scope)
        problems << "#{name}: module #{form.scope} has no sentence in Words::SCOPES: " \
                    "add one, or say @in"
      end
      options(form, name, problems)
      usage(form, name, problems)
      example(form, name, problems)
    end

    private def options(form : Words::Form, name : String, problems : Array(String)) : Nil
      listed = form.options.map(&.name)
      repeated = listed.select { |option| listed.count(option) > 1 }.uniq!
      repeated.each { |option| problems << "#{name}: @option #{option} is given twice" }
      unless form.defined?
        unless form.section.internal.empty?
          problems << "#{name}: a word the macro reads takes no @internal"
        end
        problems << "#{name}: has no code of the macro that reads it" unless read?(form)
        return
      end
      keywords = form.keywords.map(&.name)
      form.options.each do |option|
        next if keywords.includes?(option.name)
        problems << "#{name}: @option #{option.name} names no parameter with a default"
      end
      form.section.internal.each do |internal|
        next if keywords.includes?(internal)
        problems << "#{name}: @internal #{internal} names no parameter with a default"
      end
      (keywords - listed - form.section.internal).each do |parameter|
        problems << "#{name}: parameter #{parameter} has no @option or @internal line"
      end
      (listed & form.section.internal).each do |both|
        problems << "#{name}: #{both} is both an @option and @internal"
      end
    end

    # A word a macro's body reads is named in that body.
    private def read?(form : Words::Form) : Bool
      form.body.includes?(form.name)
    end

    private def usage(form : Words::Form, name : String, problems : Array(String)) : Nil
      text = form.section.usage || return
      written = text.gsub(/"[^"]*"/, "").scan(/(?<![\w:])([a-z_]+):(?!:)/).map(&.[1]).uniq!
      keywords = form.options.reject(&.positional).map(&.name)
      (written - keywords).each do |keyword|
        problems << "#{name}: @usage writes #{keyword}:, which is no @option"
      end
      (keywords - written).each do |keyword|
        problems << "#{name}: @usage does not write #{keyword}:, an @option"
      end
    end

    private def example(form : Words::Form, name : String, problems : Array(String)) : Nil
      code = form.example
      if code.nil? || code.blank?
        problems << "#{name}: has no @example"
        return
      end
      found = Calls.new
      begin
        Crystal::Parser.parse(code).accept(found)
      rescue ex : Crystal::SyntaxException
        problems << "#{name}: its @example does not parse: #{ex.message}"
        return
      end
      uses = found.calls.select { |call| call[0] == form.name }
      problems << "#{name}: its @example never uses #{form.name}" if uses.empty?
      return if form.double_splat?
      known = form.options.map(&.name)
      uses.select(&.[2]).flat_map(&.[1]).uniq!.each do |keyword|
        next if known.includes?(keyword)
        problems << "#{name}: its @example passes #{keyword}:, which is no @option"
      end
    end

    # Examples are compiled together, so two may not declare one context or kernel.
    private def declared(problems : Array(String)) : Nil
      owners = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      @words.forms.each do |form|
        code = form.example || next
        found = Calls.new
        begin
          Crystal::Parser.parse(code).accept(found)
        rescue Crystal::SyntaxException
          next
        end
        found.declared.each { |name| owners[name] << "#{form.name} (#{form.location})" }
      end
      owners.each do |name, forms|
        next if forms.size < 2
        problems << "the examples of #{forms.join(" and ")} both declare #{name}: " \
                    "name each example's context apart"
      end
    end

    private def kinds(problems : Array(String)) : Nil
      @words.words.each do |word|
        said = @words.forms_of(word).map(&.kind).uniq!
        next if said.size == 1
        problems << "word #{word} is #{said.join(" and ")} in different forms: say one kind"
      end
    end

    private def calls(snippet : {String, Int32}, origin : String, problems : Array(String)) : Nil
      code, line = snippet
      found = Calls.new
      begin
        Crystal::Parser.parse(code).accept(found)
      rescue Crystal::SyntaxException
        return
      end
      found.calls.each do |(word, keywords, plain)|
        next unless plain && @words.word?(word)
        forms = @words.forms_of(word)
        next if forms.any?(&.double_splat?)
        known = forms.flat_map(&.options).map(&.name)
        (keywords - known).uniq!.each do |keyword|
          problems << "#{origin}:#{line}: #{word} is written with #{keyword}:, " \
                      "which no form of #{word} takes (it takes #{known.uniq!.join(", ")})"
        end
      end
    end

    private def keywords(snippets : Array({String, Int32}), origin : String,
                         problems : Array(String)) : Nil
      known = @words.forms.flat_map(&.options).map(&.name).to_set | OTHER_KEYWORDS.to_set
      snippets.each do |(code, line)|
        keyword = code.match(/\A([a-z_]+):\z/).try(&.[1]) || next
        next if known.includes?(keyword)
        problems << "#{origin}:#{line}: `#{keyword}:` is no option of any SweetTalk word"
      end
    end

    # A word is named in code, in a fence or an inline span: a plain English `the` or `to` in
    # prose names nothing.
    private def mentions(snippets : Array({String, Int32}), markdown : String, origin : String,
                         problems : Array(String)) : Nil
      code = snippets.map(&.first).join('\n')
      @words.words.each do |word|
        next if code.matches?(/(?<![\w:@-])#{Regex.escape(word)}(?![\w?!:-])/)
        problems << "#{origin} never names the word #{word} in code"
      end
      options = @words.forms.flat_map(&.options).reject(&.positional).map(&.name).uniq!
      options.each do |option|
        next if markdown.matches?(/(?<![\w])#{Regex.escape(option)}:/)
        problems << "#{origin} never names the option #{option}:"
      end
    end

    # The calls in a piece of Crystal, each with the keywords it passes and whether it is
    # plain: written without a receiver and outside the block of a call that has one, as
    # a SweetTalk word is, and unlike the `tenant` of `Caramel::Router.draw`.
    private class Calls < Crystal::Visitor
      getter calls = [] of {String, Array(String), Bool}
      getter declared = [] of String
      @foreign = 0

      def visit(node : Crystal::Call) : Bool
        plain = node.obj.nil? && @foreign == 0
        @calls << {node.name, node.named_args.try(&.map(&.name)) || [] of String, plain}
        if plain && {"context", "kernel"}.includes?(node.name) && !node.args.empty?
          @declared << node.args.first.to_s
        end
        @foreign += 1 if node.obj
        true
      end

      def end_visit(node : Crystal::Call) : Nil
        @foreign -= 1 if node.obj
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end

    # Every example, grouped by the requires it needs, as one program each: the example
    # of each form in a module of its own, then `SweetTalk.boot`. *prefix* is the path
    # from the program's directory to the repository root.
    def programs(prefix : String) : Hash(Array(String), String)
      groups = {} of Array(String) => Array(Words::Form)
      @words.forms.each do |form|
        next unless form.example
        (groups[form.section.requires] ||= [] of Words::Form) << form
      end
      groups.to_h { |requires, forms| {requires, program(forms, requires, prefix)} }
    end

    private def program(forms : Array(Words::Form), requires : Array(String),
                        prefix : String) : String
      String.build do |io|
        io << "require \"" << prefix << "/src/caramel/sweet_talk\"\n"
        requires.each { |path| io << "require \"" << prefix << "/src/" << path << "\"\n" }
        forms.each_with_index(1) do |form, number|
          io << "\n# " << form.name << ", " << form.location << "\n"
          io << "module Example" << number << "\n  include SweetTalk\n\n"
          form.example.try(&.each_line { |line| io << (line.blank? ? "" : "  #{line}") << "\n" })
          io << "end\n"
        end
        io << "\nSweetTalk.boot\n"
      end
    end
  end
end
