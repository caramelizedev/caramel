require "json"
require "./words"
require "./domain_generator"

# The commands of the shard's tool program, which frappe.yml declares with run: tool:
# `sweettalk:words` and `sweettalk:make domain`. Neither needs the application to build,
# or to require the shard: the first reads the shard's sources, and the second is what adds
# the require.
#
# Whatever compiles this file requires the framework's `frappe/toolkit` and
# `caramel/version` first (ADR 0030).
module SweetTalk::Tool
  alias Kit = Caramel::Frappe::Toolkit

  # Where an application's lib/ holds the shard, from the application's root.
  SHARD = "lib/sweettalk"

  WORDS        = "sweettalk:words"
  WORDS_SYNTAX = "#{WORDS} [WORD] [--json]"
  MAKE_DOMAIN  = "sweettalk:make domain"

  # Runs the command that *arguments* name, as Frappé hands them over: its words as
  # frappe.yml writes them, then its arguments, which Frappé has held to its syntax. The
  # command runs in the application at *root*, and *agent* says who reads what it prints.
  # Returns the exit status.
  def self.run(arguments : Array(String),
               output : IO,
               error : IO,
               root : String = Kit.root,
               agent : Bool = Kit.agent?) : Int32
    options, named = arguments.partition(&.starts_with?("--"))
    if named.first? == "words" && named.size <= 2
      return words(named[1]?, options.includes?("--json"), output, error, root, agent)
    end
    means = options.find(&.starts_with?("--means=")).try(&.lchop("--means="))
    if named.size == 4 && named[0, 2] == ["make", "domain"] && means
      central = options.includes?("--central")
      return make_domain(named[2], named[3], means, central, output, error, root, agent)
    end
    Kit.failed(error, "sweettalk:#{named.join(' ')}", "unknown command", agent: agent)
    2
  end

  # `sweettalk:words [WORD] [--json]`: every word of the shard the application installed,
  # or one word; an unknown word is refused with the nearest ones.
  private def self.words(word : String?,
                         json : Bool,
                         output : IO,
                         error : IO,
                         root : String,
                         agent : Bool) : Int32
    vocabulary = Words.load(File.join(root, SHARD), root)
    return unknown(word, vocabulary.nearest(word), error, agent) if word && !vocabulary.word?(word)
    output.puts(json ? words_json(vocabulary, word) : words_text(vocabulary, word))
    0
  rescue ex : Caramel::Frappe::Error
    Kit.failed(error, WORDS, ex.message.to_s, agent: agent)
    1
  end

  private def self.words_text(vocabulary : Words, word : String?) : String
    (word ? vocabulary.to_text(word) : vocabulary.to_text).chomp
  end

  private def self.words_json(vocabulary : Words, word : String?) : String
    return vocabulary.to_json unless word
    JSON.build { |builder| vocabulary.word_json(builder, word) }
  end

  # Refuses *word*, which is no word, as Frappé refuses a malformed command: with the
  # command's syntax and the nearest word.
  private def self.unknown(word : String,
                           nearest : Array(String),
                           error : IO,
                           agent : Bool) : Int32
    message = "unknown word #{word}"
    message += "; nearest: #{nearest.join(", ")}" unless nearest.empty?
    suggestion = nearest.first?
    if agent
      fields = [{"MSG", message}, {"SYNTAX", "frappe #{WORDS_SYNTAX}"}]
      fields << {"SUGGEST", suggestion} if suggestion
      Caramel::Frappe::MRDP.write(error, "USAGE", "frappe #{WORDS}", fields)
    else
      error.puts("frappe #{WORDS}: #{message}")
      error.puts("Usage: frappe #{WORDS_SYNTAX}")
      error.puts("Did you mean #{suggestion}?") if suggestion
      error.puts("Run frappe #{WORDS} --help for details.")
    end
    1
  end

  # `sweettalk:make domain NAME CONTEXT --means=TEXT [--central]`: writes the domain and
  # says what to run next.
  private def self.make_domain(name : String,
                               context : String,
                               means : String,
                               central : Bool,
                               output : IO,
                               error : IO,
                               root : String,
                               agent : Bool) : Int32
    files = DomainGenerator.new.generate(root, name, context, means, central: central)
    Kit.generated(output, files)
    singular = name.underscore
    steps = [{"Write the domain in app/domain/#{singular}.cr.", ""},
             {"frappe db diff --name create_#{singular}", "derive its tables"},
             {"frappe migrate", "apply them"}]
    Kit.next_steps(output, steps)
    0
  rescue ex : Caramel::Frappe::Error | File::Error
    Kit.failed(error, MAKE_DOMAIN, ex.message.to_s, agent: agent)
    1
  end
end
