require "set"
require "./document"
require "./pattern"

module Corretto::HTML
  class Comparison
    getter mismatch : String? = nil

    def initialize(@strict : Bool = false)
    end

    def matches?(pattern : Pattern, node : Lexbor::Node, path = pattern.description) : Bool
      @mismatch = nil
      compare(pattern, node, path)
    end

    private def compare(pattern, node, path) : Bool
      unless pattern.tag == node.tag_name.downcase
        return miss(path, "expected <#{pattern.tag}>, got <#{node.tag_name}>")
      end
      return false unless attributes_match?(pattern, node, path)
      if expected = pattern.text
        unless normalize(expected, node) == normalize(node.inner_text, node)
          return miss(path, "expected text #{expected.inspect}, got #{node.inner_text.inspect}")
        end
      end
      @strict ? strict_children?(pattern, node, path) : selected_children?(pattern, node, path)
    end

    private def attributes_match?(pattern, node, path) : Bool
      actual = node.attributes
      pattern.attributes.each do |name, expected|
        unless attribute_matches?(name, expected, actual[name]?)
          return miss(path, "expected #{name}=#{expected.inspect}, got #{actual[name]?.inspect}")
        end
      end
      if @strict
        names = pattern.attributes.reject { |_, value| value == false }.keys.sort!
        unless actual.keys.sort! == names
          return miss(path, "unexpected attributes #{actual.keys - names}")
        end
      end
      true
    end

    private def attribute_matches?(name, expected, actual) : Bool
      case expected
      when Bool
        expected == !actual.nil?
      when String
        return false unless actual
        return actual == expected unless name == "class"
        wanted = class_tokens(expected)
        found = class_tokens(actual)
        @strict ? wanted == found : (wanted - found).empty?
      else
        false
      end
    end

    private def selected_children?(pattern, node, path) : Bool
      missing = nil
      choices = pattern.children.map do |requirement|
        candidates = requirement.is_a?(String) ? node.children.to_a : node.scope.to_a
        candidates.select! { |child| candidate?(requirement, child) }
        reason = nil
        matches = candidates.select do |child|
          matched = child_matches?(requirement, child, path, node)
          reason ||= @mismatch unless matched
          matched
        end
        if matches.empty?
          expected = requirement.is_a?(Pattern) ? requirement.description : requirement.inspect
          missing ||= reason || "#{path} > #{expected}: no matching node"
        end
        matches
      end
      if distinct?(choices)
        @mismatch = nil
        return true
      end
      @mismatch = missing || "#{path}: nested requirements need distinct matching nodes"
      false
    end

    private def candidate?(requirement : String, node) : Bool
      node.is_text?
    end

    private def candidate?(requirement : Pattern, node) : Bool
      !node.is_text? && !node.is_comment? && node.tag_name == requirement.tag
    end

    # Assign each requirement a node, moving an earlier assignment when
    # necessary. An augmenting path avoids factorial searches for repeated li's.
    private def distinct?(choices) : Bool
      owners = {} of Lexbor::Lib::DomElementT => Int32
      choices.each_index.all? do |index|
        assign?(choices, index, owners, Set(Lexbor::Lib::DomElementT).new)
      end
    end

    private def assign?(choices, index, owners, visited) : Bool
      choices[index].any? do |candidate|
        element = candidate.element
        next false unless visited.add?(element)
        previous = owners[element]?
        if previous.nil? || assign?(choices, previous, owners, visited)
          owners[element] = index
          true
        else
          false
        end
      end
    end

    private def strict_children?(pattern, node, path) : Bool
      wanted = pattern.children.dup
      wanted << pattern.text.to_s if pattern.text
      wanted.reject! { |item| item.is_a?(String) && normalize(item, node).empty? }
      actual = [] of Lexbor::Node | String
      node.children.each do |child|
        next if child.is_comment?
        if child.is_text?
          previous = actual.last?
          if previous.is_a?(String)
            actual[-1] = previous + child.tag_text
          else
            actual << child.tag_text
          end
        else
          actual << child
        end
      end
      actual.reject! { |child| child.is_a?(String) && normalize(child, node).empty? }
      unless actual.size == wanted.size
        return miss(path, "expected #{wanted.size} direct children, got #{actual.size}")
      end
      wanted.zip(actual).all? do |requirement, child|
        strict_match?(requirement, child, path, node)
      end
    end

    private def strict_match?(requirement, child : Lexbor::Node, path, parent) : Bool
      child_matches?(requirement, child, path, parent)
    end

    private def strict_match?(requirement, child : String, path, parent) : Bool
      matches = requirement.is_a?(String) &&
                normalize(requirement, parent) == normalize(child, parent)
      expected = requirement.is_a?(Pattern) ? requirement.description : requirement.inspect
      matches || miss(path, "expected #{expected}, got direct text #{child.inspect}")
    end

    private def child_matches?(requirement : String, child, path, parent) : Bool
      matches = child.is_text? &&
                normalize(requirement, parent) == normalize(child.tag_text, parent)
      matches || miss(path, "expected direct text #{requirement.inspect}")
    end

    private def child_matches?(requirement : Pattern, child, path, parent) : Bool
      return false if child.is_text? || child.is_comment?
      compare(requirement, child, "#{path} > #{requirement.description}")
    end

    private def normalize(text : String, node) : String
      preserve = preformatted?(node) || node.parents.any? { |parent| preformatted?(parent) }
      preserve ? text : text.gsub(/[\t\n\f\r ]+/, " ").strip(' ')
    end

    private def class_tokens(value) : Array(String)
      value.split(/[\t\n\f\r ]+/).reject!(&.empty?).uniq!.sort!
    end

    private def preformatted?(node) : Bool
      node.tag_id.in?(Lexbor::Lib::TagIdT::LXB_TAG_PRE, Lexbor::Lib::TagIdT::LXB_TAG_TEXTAREA)
    end

    private def miss(path, reason) : Bool
      @mismatch = "#{path}: #{reason}"
      false
    end
  end
end
