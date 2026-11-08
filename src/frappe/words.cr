require "compiler/crystal/syntax"
require "json"
require "./commands"
require "./word_doc"
require "./terminal"

module Caramel::Frappe
  # `frappe words`: SweetTalk's vocabulary as its own macros state it. Each word's macro
  # (or method) in `src/caramel/sweet_talk` carries a block of tags in its doc comment
  # (`WordDoc`), and Crystal's parser reads the macro's parameters beside it, so the
  # reference cannot name an option the word lacks or leave one out (`WordDrift` holds it
  # to that). Frappé reads the sources of its own release, so no application is needed.
  class Words
    # What a word does for the author, in the order `frappe words` lists them.
    KINDS = {
      "noun"      => "declares a thing the glossary lists",
      "attribute" => "says what a noun holds",
      "rule"      => "states what must hold",
      "behaviour" => "says what happens",
      "query"     => "reads rows",
      "boundary"  => "draws a line between contexts or around the program",
      "setup"     => "is written once before the contexts",
    }

    # Where the macros of each module may be written. A form's `@in` replaces it.
    SCOPES = {
      "SweetTalk"                 => "at the top level of a domain module",
      "SweetTalk::BoundedContext" => "in a context or a kernel",
      "SweetTalk::Aggregate"      => "in an aggregate",
      "SweetTalk::Holding"        => "in an aggregate or an entity",
      "SweetTalk::Lifecycle"      => "in an aggregate or a process",
      "SweetTalk::Model"          => "in an aggregate, an entity, a projection or a process",
      "SweetTalk::Process"        => "in a process",
      "SweetTalk::Projection"     => "in a projection",
      "SweetTalk::Queried"        => "in an aggregate, a projection or a process",
      "SweetTalk::Guarded"        => "in an aggregate, an entity, a unit or a value with parts",
      "SweetTalk::Composite"      => "in a value with parts",
    }

    # Macros the compiler calls itself: not words.
    HOOKS = %w[finished]

    SOURCE = "src/caramel/sweet_talk"

    record Param, name : String, default : String?, kind : Symbol

    # One definition of a word: a macro, a method, or a word that a macro's body reads.
    class Form
      getter name : String
      getter scope : String
      getter file : String
      getter line : Int32
      getter params : Array(Param)
      getter section : WordDoc::Section
      getter body : String
      getter? defined : Bool

      def initialize(@name, @scope, @file, @line, @params, @section, @body, @defined)
      end

      def where : String
        @section.where || SCOPES[@scope]? || @scope
      end

      def kind : String
        @section.kind
      end

      def location : String
        "#{@file}:#{@line}"
      end

      # What the macro's parameters accept as keywords: those with a default.
      def keywords : Array(Param)
        @params.select(&.default)
      end

      def options : Array(WordDoc::Option)
        @section.options
      end

      def example : String?
        @section.example
      end

      def double_splat? : Bool
        @params.any? { |param| param.kind == :double_splat && param.name != "unknown" }
      end
    end

    # A refusing macro: it defines no word, it says where the word does not belong.
    record Stub, name : String, scope : String, location : String

    # A macro or method that has no tags and is no refusal.
    record Untagged, name : String, location : String

    getter root : String
    getter forms = [] of Form
    getter stubs = [] of Stub
    getter untagged = [] of Untagged
    getter notes = [] of String

    def self.load(root : String) : Words
      directory = File.join(root, SOURCE)
      unless Dir.exists?(directory)
        raise Error.new("This Frappé has no SweetTalk source: #{directory} does not exist")
      end
      words = new(root)
      Dir.glob(File.join(directory, "**/*.cr")).sort!.each { |file| words.read(file) }
      words
    end

    def initialize(@root : String)
    end

    # Every word, in the order of its first form, with its forms in source order.
    def words : Array(String)
      @forms.map(&.name).uniq!
    end

    def forms_of(name : String) : Array(Form)
      @forms.select { |form| form.name == name }
    end

    def word?(name : String) : Bool
      @forms.any? { |form| form.name == name }
    end

    # Up to three words close to *name*, nearest first.
    def nearest(name : String) : Array(String)
      scored = words.map { |word| {Commands.distance(name, word), word} }
      limit = name.size >= 5 ? 2 : 1
      near = scored.select { |(distance, _)| distance <= limit }
      near.sort_by!(&.first).first(3).map(&.last)
    end

    protected def read(file : String) : Nil
      relative = file.lchop(@root).lstrip('/')
      parser = Crystal::Parser.new(File.read(file))
      parser.wants_doc = true
      parser.filename = file
      reader = Reader.new(self, relative)
      parser.parse.accept(reader)
    rescue ex : Crystal::SyntaxException
      @notes << "#{relative} does not parse: #{ex.message}"
    end

    protected def add(form : Form) : Nil
      @forms << form
    end

    protected def refuse(stub : Stub) : Nil
      @stubs << stub
    end

    protected def skip(untagged : Untagged) : Nil
      @untagged << untagged
    end

    # Walks one file: the macros and the tagged methods, with the module that holds each.
    private class Reader < Crystal::Visitor
      def initialize(@words : Words, @file : String)
        @path = [] of String
      end

      def visit(node : Crystal::ModuleDef | Crystal::ClassDef) : Bool
        @path << node.name.to_s
        node.body.accept(self)
        @path.pop
        false
      end

      def visit(node : Crystal::Macro) : Bool
        return false if node.name.starts_with?("__") || HOOKS.includes?(node.name)
        scope = @path.join("::")
        location = "#{@file}:#{node.location.try(&.line_number)}"
        if blocks = blocks(node.doc)
          blocks.each_with_index { |section, index| form(node, section, scope, index) }
        elsif Words.refusal?(node.body)
          @words.refuse(Stub.new(node.name, scope, location))
        else
          @words.skip(Untagged.new(node.name, location))
        end
        false
      end

      def visit(node : Crystal::Def) : Bool
        blocks = blocks(node.doc) || return false
        blocks.each_with_index { |section, index| form(node, section, @path.join("::"), index) }
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def blocks(doc : String?) : Array(WordDoc::Section)?
        parsed = WordDoc.new(doc || "")
        parsed.sections if parsed.blocks?
      end

      private def form(node : Crystal::Macro | Crystal::Def, section : WordDoc::Section,
                       scope : String, index : Int32) : Nil
        name = section.name || node.name
        line = node.location.try(&.line_number) || 0
        own = section.name.nil?
        @words.add(Form.new(name, scope, @file, line, own ? Words.params(node) : [] of Param,
          section, node.is_a?(Crystal::Macro) ? node.body.to_s : "", own))
      end
    end

    # The parameters of a macro or method: what its caller may pass.
    def self.params(node : Crystal::Macro | Crystal::Def) : Array(Param)
      params = node.args.map_with_index do |arg, index|
        kind = index == node.splat_index ? :splat : :plain
        Param.new(arg.name, arg.default_value.try(&.to_s), kind)
      end
      node.double_splat.try { |arg| params << Param.new(arg.name, nil, :double_splat) }
      node.block_arg.try { |arg| params << Param.new(arg.name, nil, :block) }
      params
    end

    # Whether *body* only refuses: it holds no code to expand and its macro expressions
    # raise unconditionally, as `unit` does in an aggregate.
    def self.refusal?(body : Crystal::ASTNode) : Bool
      nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
      raised = false
      nodes.each do |node|
        case node
        when Crystal::MacroLiteral
          return false unless node.value.blank?
        when Crystal::MacroExpression
          return false if node.output?
          raised ||= raises?(node.exp)
          return false unless refusing_expression?(node.exp)
        else
          return false
        end
      end
      raised
    end

    private def self.raises?(node : Crystal::ASTNode) : Bool
      case node
      when Crystal::Call        then node.name == "raise"
      when Crystal::Expressions then node.expressions.any? { |inner| raises?(inner) }
      else                           false
      end
    end

    private def self.refusing_expression?(node : Crystal::ASTNode) : Bool
      if node.is_a?(Crystal::Expressions)
        return node.expressions.all? { |inner| refusing_expression?(inner) }
      end
      node.is_a?(Crystal::Call) || node.is_a?(Crystal::Assign)
    end

    # The guide's section for *anchor* in this release's Markdown edition.
    def self.guide_url(anchor : String) : String
      "#{Caramel::WEBSITE}/docs/#{Caramel::VERSION}/sweettalk/index.md##{anchor}"
    end

    # Every word with its kind and summary, grouped by kind.
    def to_text : String
      String.build do |io|
        io << "SweetTalk words in Caramel " << Caramel::VERSION << ": " << words.size
        io << ". frappe words WORD prints a word's usage, options and example.\n"
        KINDS.each do |kind, meaning|
          listed = words.select { |word| first(word).kind == kind }.sort!
          next if listed.empty?
          io << "\n" << kind << ": " << meaning << "\n"
          width = listed.max_of(&.size)
          listed.each do |word|
            io << "  " << word.ljust(width) << "  " << first(word).section.summary << "\n"
          end
        end
      end
    end

    # One word: each form with where it is written, its usage, options and example.
    def to_text(word : String) : String
      forms = forms_of(word)
      String.build do |io|
        io << word << " (" << forms.first.kind << ")\n"
        forms.each { |form| form_text(io, form) }
      end
    end

    private def form_text(io : IO, form : Form) : Nil
      io << "\n" << Words.capitalized(form.where) << ": " << form.section.summary << "\n"
      io << "  " << (form.section.usage || form.name) << "\n"
      guide = form.section.guide
      io << "  Guide: " << Words.guide_url(guide) << "\n" if guide
      unless form.options.empty?
        io << "\n  Options\n"
        form.options.each { |option| option_text(io, option) }
      end
      example = form.example
      return unless example
      io << "\n  Example, compiled by scripts/check sweet-talk-compilation\n"
      example.each_line { |line| io << (line.blank? ? "" : "    #{line}") << "\n" }
    end

    private def option_text(io : IO, option : WordDoc::Option) : Nil
      io << "    " << option.name << (option.positional ? "" : ":") << "  " << option.forms
      io << "; default " << option.default if option.default
      io << "\n"
      Terminal.wrap(option.does, 88).each { |line| io << "        " << line << "\n" }
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "version", Caramel::VERSION
        json.field "words" do
          json.array { words.each { |word| word_json(json, word) } }
        end
      end
    end

    def word_json(json : JSON::Builder, word : String) : Nil
      forms = forms_of(word)
      json.object do
        json.field "word", word
        json.field "kind", forms.first.kind
        json.field "summary", forms.first.section.summary
        json.field "forms" do
          json.array { forms.each { |form| form_json(json, form) } }
        end
      end
    end

    private def form_json(json : JSON::Builder, form : Form) : Nil
      section = form.section
      json.object do
        json.field "in", form.where
        json.field "summary", section.summary
        json.field "usage", section.usage
        json.field "options" do
          json.array { form.options.each { |option| option_json(json, option) } }
        end
        json.field "example", form.example
        json.field "requires", section.requires
        json.field "guide", section.guide.try { |anchor| Words.guide_url(anchor) }
        json.field "source", form.location
      end
    end

    private def option_json(json : JSON::Builder, option : WordDoc::Option) : Nil
      json.object do
        json.field "name", option.name
        json.field "forms", option.forms
        json.field "default", option.default
        json.field "does", option.does
        json.field "positional", option.positional
      end
    end

    private def first(word : String) : Form
      forms_of(word).first
    end

    def self.capitalized(text : String) : String
      text.empty? ? text : text[0].upcase + text[1..]
    end
  end
end
