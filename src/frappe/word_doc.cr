module Caramel::Frappe
  # The block of tags that describes a SweetTalk word, written once in the doc comment of
  # the macro (or method) that defines it, after the prose for contributors:
  #
  #     # @word noun | One sentence that says what the word does.
  #     # @usage value NAME, TYPE[, at_least: N][, means: TEXT]
  #     # @in a context or a kernel
  #     # @option at_least | integer literal | - | The smallest value.
  #     #   A continuation line starts with two spaces.
  #     # @internal border
  #     # @guide c-sweettalk-values
  #     # @example requires caramel/sweet_talk/money
  #     #   context Till, means: "money taken" do
  #     #   end
  #
  # `@word` opens a form of a word: `@word NAME KIND | summary` names a word the macro's
  # body reads rather than defines, such as `warn` in a unit. `@in` replaces the sentence
  # the form's module gives. An `@option` has four cells, `NAME [positional] | forms |
  # default | what it does`, where a default of `-` says it has none. `Words` reads the
  # block; `WordDrift` holds it to the macro's parameters.
  struct WordDoc
    record Section,
      name : String?,
      kind : String,
      summary : String,
      usage : String?,
      where : String?,
      options : Array(Option),
      internal : Array(String),
      guide : String?,
      example : String?,
      requires : Array(String),
      problems : Array(String)

    record Option,
      name : String,
      forms : String,
      default : String?,
      does : String,
      positional : Bool

    TAG = /\A@(word|usage|in|option|internal|guide|example)(?:\s+(.*))?\z/

    alias Tagged = {String, String, Array(String)}

    getter sections = [] of Section

    @current : Array(Tagged)? = nil
    @stray = [] of String

    # Parses *doc*, a doc comment with its `# ` removed. Prose before the first `@word` is
    # for contributors and ignored; a line after it that is no tag or continuation is a
    # problem the section carries.
    def initialize(doc : String)
      tagged = false
      doc.each_line do |line|
        if line.starts_with?('@')
          tagged = true
          tag_line(line)
        elsif tagged
          continuation(line)
        end
      end
      close
    end

    def blocks? : Bool
      !@sections.empty?
    end

    private def tag_line(line : String) : Nil
      tag = line.match(TAG)
      unless tag
        @stray << "the line #{line.inspect} is no tag; the tags are @word, @usage, @in, " \
                  "@option, @internal, @guide and @example"
        return
      end
      if tag[1] == "word"
        close
        @current = [] of Tagged
      end
      current = @current
      if current
        current << {tag[1], tag[2]? || "", [] of String}
      else
        @stray << "#{tag[0].inspect} comes before any @word"
      end
    end

    private def continuation(line : String) : Nil
      last = @current.try(&.last?)
      if last && (line.blank? || line.starts_with?("  "))
        last[2] << line
      elsif !line.blank?
        @stray << "the line #{line.inspect} is no tag; indent a continuation by two spaces"
      end
    end

    private def close : Nil
      current = @current || return
      @current = nil
      @sections << build(current)
    end

    private def build(tags : Array(Tagged)) : Section
      problems = @stray.dup
      @stray.clear
      head = tags.first
      said = ([head[1]] + head[2].map(&.strip)).join(' ').strip
      name, kind, summary = word_line(said, problems)
      usage = where = guide = example = nil
      requires = [] of String
      options = [] of Option
      internal = [] of String
      tags[1..].each do |(tag, text, more)|
        joined = ([text] + more.map(&.strip)).reject(&.empty?).join(' ')
        case tag
        when "usage"  then usage = one(usage, tag, joined, problems)
        when "in"     then where = one(where, tag, joined, problems)
        when "guide"  then guide = one(guide, tag, joined, problems)
        when "option" then option(joined, options, problems)
        when "internal"
          internal.concat(joined.split(',').map(&.strip).reject(&.empty?))
        else
          example, requires = code(example, text, more, problems)
        end
      end
      Section.new(name, kind, summary, usage, where, options, internal, guide, example,
        requires, problems)
    end

    private def word_line(text : String, problems : Array(String)) : {String?, String, String}
      head, bar, summary = text.partition(" | ")
      names = head.split
      problems << "@word reads `@word [NAME] KIND | summary`, not #{text.inspect}" if bar.empty?
      name = names.size > 1 ? names.first : nil
      {name, names.last? || "", summary.strip}
    end

    private def one(held : String?, tag : String, text : String, problems : Array(String)) : String
      problems << "@#{tag} is given twice" if held
      text
    end

    private def option(text : String, options : Array(Option), problems : Array(String)) : Nil
      cells = text.split(" | ", 4)
      if cells.size != 4 || cells[0].blank?
        problems << "@option reads `@option NAME | forms | default | what it does`, " \
                    "not #{text.inspect}"
        return
      end
      names = cells[0].split
      positional = names[1]? == "positional"
      if names.size > (positional ? 2 : 1)
        problems << "@option #{cells[0].inspect} takes a name and optionally `positional`"
      end
      default = cells[2].strip
      options << Option.new(names[0], cells[1].strip, default == "-" ? nil : default,
        cells[3].strip, positional)
    end

    private def code(held : String?, text : String, more : Array(String),
                     problems : Array(String)) : {String?, Array(String)}
      problems << "@example is given twice" if held
      requires = [] of String
      unless text.blank?
        head, _, rest = text.partition(' ')
        if head == "requires"
          requires = rest.split
        else
          problems << "@example reads `@example [requires PATH...]`, not #{text.inspect}"
        end
      end
      lines = more.map { |line| line.starts_with?("  ") ? line[2..] : line }
      last = lines.rindex { |line| !line.blank? } || -1
      lines = lines[0..last]
      {lines.join('\n'), requires}
    end
  end
end
