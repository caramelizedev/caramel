require "blueprint/html/standard_elements"

module Corretto::HTML
  alias Attribute = String | Bool

  # An expectation, independent of Blueprint's HTML renderer.
  class Pattern
    getter tag : String
    getter attributes = {} of String => Attribute
    getter children = [] of Pattern | String
    property text : String? = nil

    def initialize(@tag : String)
    end

    def attribute(name : String, value : NamedTuple | Hash) : Nil
      value.each { |key, item| attribute("#{name}-#{key}", item) }
    end

    def attribute(name : String, value : Array) : Nil
      attribute(name, value.flatten.compact.join(' '))
    end

    def attribute(name : String, value : Bool) : Nil
      @attributes[name.tr("_", "-")] = value
    end

    def attribute(name : String, value : Nil) : Nil
      attribute(name, false)
    end

    def attribute(name : String, value) : Nil
      @attributes[name.tr("_", "-")] = value.to_s
    end

    def description : String
      suffix = attributes.join { |name, value| "[#{name}=#{value.inspect}]" }
      "#{tag}#{suffix}"
    end

    def summary : String
      requirements = children.map do |child|
        child.is_a?(Pattern) ? child.summary : "plain #{child.inspect}"
      end
      requirements << text.inspect if text
      return description if requirements.empty?
      "#{description} { #{requirements.join("; ")} }"
    end
  end

  # Blueprint supplies the vocabulary; these macros record requirements
  # instead of rendering expected markup through the code under test.
  class PatternBuilder
    macro register_element(method_name, tag = nil)
      {% tag ||= method_name.tr("_", "-") %}
      def {{ method_name.id }}(**attributes, &) : Nil
        element("{{ tag.id }}", **attributes) { yield }
      end

      def {{ method_name.id }}(**attributes) : Nil
        element("{{ tag.id }}", **attributes)
      end
    end

    macro register_void_element(method_name, tag = nil)
      {% tag ||= method_name.tr("_", "-") %}
      def {{ method_name.id }}(**attributes) : Nil
        element("{{ tag.id }}", **attributes)
      end
    end

    macro register_empty_element(method_name, tag = nil)
      register_void_element {{ method_name }}, {{ tag }}
    end

    include Blueprint::HTML::StandardElements

    getter roots = [] of Pattern
    @stack = [] of Pattern

    def self.build(&) : Pattern
      builder = new
      yield builder
      unless builder.roots.size == 1
        raise ArgumentError.new("An HTML expectation requires exactly one root element")
      end
      builder.roots.first
    end

    def element(tag : String, **attributes) : Nil
      add(tag, attributes)
    end

    def element(tag : String, **attributes, &) : Nil
      node = add(tag, attributes)
      @stack << node
      begin
        record_text(node, yield)
      ensure
        @stack.pop
      end
    end

    def plain(text : String) : Nil
      parent = @stack.last? || raise ArgumentError.new("plain requires an element scope")
      previous = parent.children.last?
      if previous.is_a?(String)
        parent.children[-1] = previous + text
      else
        parent.children << text
      end
    end

    private def record_text(node : Pattern, value : String) : Nil
      node.text = value
    end

    private def record_text(node : Pattern, value : Number | Bool | Char) : Nil
      node.text = value.to_s if node.children.empty?
    end

    private def record_text(node : Pattern, value) : Nil
      return unless node.children.empty?
      return if value.nil? || value.responds_to?(:each)
      message = "Unsupported HTML text value #{value.class} in <#{node.tag}>; use .to_s"
      raise ArgumentError.new(message)
    end

    private def add(tag, attributes) : Pattern
      unless tag.matches?(/\A[a-zA-Z][a-zA-Z0-9:_-]*\z/)
        raise ArgumentError.new("Invalid HTML element name: #{tag.inspect}")
      end
      node = Pattern.new(tag.downcase)
      attributes.each { |name, value| node.attribute(name.to_s, value) }
      if parent = @stack.last?
        parent.children << node
      else
        @roots << node
      end
      node
    end
  end
end
