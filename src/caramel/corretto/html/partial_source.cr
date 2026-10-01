require "lexbor"

module Corretto::HTML
  {% unless Lexbor::VERSION == "3.6.4" %}
    {% raise "Review Corretto's native template layouts before changing the pinned Lexbor shard" %}
  {% end %}

  # Lexbor 3.0.0's template content is a separate document fragment. These
  # private layouts follow dom/interfaces/node.h, element.h and
  # html/interfaces/template_element.h in the pinned native dependency.
  # The shard binds navigation but does not expose template.content.
  lib TemplateNative
    DOCUMENT_FRAGMENT = 11

    struct Node
      events : Void*
      local_name : LibC::SizeT
      prefix : LibC::SizeT
      namespace : LibC::SizeT
      owner_document : Void*
      next : Void*
      previous : Void*
      parent : Void*
      first_child : Void*
      last_child : Void*
      user : Void*
      type : Int32
    end

    struct Element
      node : Node
      upper_name : LibC::SizeT
      qualified_name : LibC::SizeT
      is_value : Void*
      first_attribute : Void*
      last_attribute : Void*
      id_attribute : Void*
      class_attribute : Void*
      style : Void*
      list : Void*
      condition : Int32
      custom_state : Int32
    end

    struct Template
      element : Element
      content : Void*
    end

    fun node_type = lxb_dom_node_type_noi(node : Void*) : Int32
  end

  # htmx reads hx-partial as template content before HTML5 parsing. Rename
  # only real envelope tokens, keeping raw text, comments and attributes
  # byte-for-byte. Restore the envelope after parsing its inert contents.
  private class PartialSource < Lexbor::Tokenizer::State
    getter marker : String
    @changes = [] of Tuple(Int32, Int32, String)

    def initialize(@source : String)
      @marker = "data-corretto-partial"
      lowered = @source.downcase
      while lowered.includes?(@marker)
        @marker += "x"
      end
    end

    def on_token(token)
      return if token.textable?
      return if token.tag_id == Lexbor::Lib::TagIdT::LXB_TAG__EM_DOCTYPE
      return if token.tag_id == Lexbor::Lib::TagIdT::LXB_TAG__END_OF_FILE
      raw = token.raw_token
      return if raw.begin_.null? || raw.end_.null?
      name = String.new(raw.begin_, raw.end_ - raw.begin_)
      return unless name.downcase == "hx-partial"
      start = (raw.begin_ - @source.to_unsafe).to_i
      replacement = token.closed? ? "template" : "template #{@marker}"
      @changes << {start, name.bytesize, replacement}
    end

    def html : String
      return @source if @changes.empty?
      String.build do |io|
        position = 0
        @changes.each do |start, length, replacement|
          io.write @source.to_slice[position, start - position]
          io << replacement
          position = start + length
        end
        io.write @source.to_slice[position, @source.bytesize - position]
      end
    end

    def restore(root : Lexbor::Node, parser : Lexbor::Parser) : Nil
      root.scope.to_a.each do |node|
        next unless node.tag_id == Lexbor::Lib::TagIdT::LXB_TAG_TEMPLATE
        next unless node.has_key?(@marker)
        content = template_content(node)
        restore(content, parser)
        envelope = parser.create_node("hx-partial")
        node.attributes.each do |name, value|
          envelope.attribute_add(name, value) unless name == @marker
        end
        content.children.to_a.each do |child|
          child.remove!
          envelope.append_child(child)
        end
        node.insert_before(envelope)
        node.remove!
      end
    end

    private def template_content(node) : Lexbor::Node
      namespace = node.element.as(TemplateNative::Node*).value.namespace
      unless namespace == Lexbor::Lib::NsIdT::LXB_NS_HTML.value
        raise Lexbor::LibError.new("An hx-partial envelope requires the HTML namespace")
      end
      pointer = node.element.as(TemplateNative::Template*).value.content
      if pointer.null? || TemplateNative.node_type(pointer) != TemplateNative::DOCUMENT_FRAGMENT
        raise Lexbor::LibError.new("Cannot read the pinned Lexbor template content")
      end
      Lexbor::Node.new(node.parser, pointer.as(Lexbor::Lib::DomElementT))
    end
  end
end
