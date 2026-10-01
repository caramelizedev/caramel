require "lexbor"
require "./partial_source"

module Corretto::HTML
  # Token metadata chooses the HTML5 fragment context and identifies htmx
  # envelopes. Structure, attributes and text come from Lexbor's DOM parser.
  private class Context < PartialSource
    getter first : Lexbor::Lib::TagIdT? = nil
    getter? document = false

    def on_token(token)
      super
      tag = token.tag_id
      if tag == Lexbor::Lib::TagIdT::LXB_TAG__EM_DOCTYPE
        @document = true unless @first
      elsif !token.closed? && !tag.in?(Lexbor::Lib::TagIdT::LXB_TAG__TEXT,
              Lexbor::Lib::TagIdT::LXB_TAG__EM_COMMENT) && !@first
        @first = tag
        @document = true if tag == Lexbor::Lib::TagIdT::LXB_TAG_HTML
      end
    end

    def parent : String
      case @first
      when .in?(Lexbor::Lib::TagIdT::LXB_TAG_TD, Lexbor::Lib::TagIdT::LXB_TAG_TH)
        "tr"
      when Lexbor::Lib::TagIdT::LXB_TAG_TR
        "tbody"
      when .in?(Lexbor::Lib::TagIdT::LXB_TAG_TBODY, Lexbor::Lib::TagIdT::LXB_TAG_THEAD,
        Lexbor::Lib::TagIdT::LXB_TAG_TFOOT, Lexbor::Lib::TagIdT::LXB_TAG_CAPTION,
        Lexbor::Lib::TagIdT::LXB_TAG_COLGROUP)
        "table"
      when Lexbor::Lib::TagIdT::LXB_TAG_COL
        "colgroup"
      when .in?(Lexbor::Lib::TagIdT::LXB_TAG_OPTION, Lexbor::Lib::TagIdT::LXB_TAG_OPTGROUP)
        "select"
      else
        "body"
      end
    end
  end

  # Owns native memory for one assertion. No node escapes the block passed
  # to .open; diagnostics are copied to Crystal strings before closing.
  class Document
    getter root : Lexbor::Node
    getter? full_page : Bool
    @parser : Lexbor::Parser

    def initialize(source : String)
      context = Context.new(source)
      context.parse(source)
      @parser = Lexbor.new(context.document? ? context.html : "")
      @root = parse_root(context)
      @full_page = context.document? && @root.children.any? do |node|
        node.tag_id == Lexbor::Lib::TagIdT::LXB_TAG__EM_DOCTYPE
      end
    ensure
      context.try(&.free)
    end

    private def parse_root(context) : Lexbor::Node
      root = context.document? ? @parser.document! : @parser.create_node(context.parent)
      root.inner_html = context.html unless context.document?
      context.restore(root, @parser)
      root
    rescue ex
      @parser.free
      raise ex
    end

    def self.open(source : String, &)
      document = new(source)
      yield document
    rescue ex : Lexbor::Error
      raise ArgumentError.new("Cannot inspect HTML: #{ex.message}")
    ensure
      document.try(&.close)
    end

    def close : Nil
      @parser.free
    end

    def select(selector : String) : Array(Lexbor::Node)
      result = [] of Lexbor::Node
      @root.css(selector) { |node| result << node unless node.element == @root.element }
      result
    end

    def elements : Array(Lexbor::Node)
      @root.scope.reject { |node| node.is_text? || node.is_comment? || doctype?(node) }.to_a
    end

    private def doctype?(node) : Bool
      node.tag_id == Lexbor::Lib::TagIdT::LXB_TAG__EM_DOCTYPE
    end
  end
end
