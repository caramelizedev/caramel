# SPDX-License-Identifier: Apache-2.0
# Adapts Crystal 1.21 ECR processor conventions (Apache-2.0).
# Changes: escaped expression output and Caramel macro integration.
# See THIRD_PARTY_NOTICES.md and vendor/licenses/crystal-LICENSE.
require "ecr/lexer"

module Caramel
  module View
    # Translates ECR tokens into Crystal statements for the View.render macro.
    # The compiler keeps ECR's source location annotations so errors in a
    # template are reported against the template rather than this generator.
    module Compiler
      extend self

      DefaultBufferName = "__io__"

      def process_file(filename : String, buffer_name = DefaultBufferName) : String
        process_string(File.read(filename), filename, buffer_name)
      end

      def process_string(source : String, filename : String, buffer_name = DefaultBufferName) : String
        lexer = ECR::Lexer.new(source)
        token = lexer.next_token

        String.build do |output|
          loop do
            case token.type
            when .string?
              literal = token.value
              token = lexer.next_token
              literal = suppress_leading_indentation(token, literal)

              output << buffer_name
              output << " << " << literal.inspect << '\n'
            when .output?
              expression = token.value
              line_number = token.line_number
              column_number = token.column_number
              suppress_trailing = token.suppress_trailing?
              token = lexer.next_token
              suppress_trailing_whitespace(token, suppress_trailing)

              output << "#<loc:push>(::Caramel::HTML.escape("
              append_source_location(output, filename, line_number, column_number)
              output << expression
              output << "))#<loc:pop>.to_s " << buffer_name << '\n'
            when .control?
              control = token.value
              line_number = token.line_number
              column_number = token.column_number
              suppress_trailing = token.suppress_trailing?
              token = lexer.next_token
              suppress_trailing_whitespace(token, suppress_trailing)

              append_location(output, filename, line_number, column_number)
              output << ' ' unless control.starts_with?(' ')
              output << control
              output << "#<loc:pop>\n"
            when .eof?
              break
            end
          end
        end
      end

      private def suppress_leading_indentation(token, string)
        # Match ECR's whitespace suppression semantics for <%-style control
        # and output tags while keeping the standard lexer in charge.
        if (token.type.output? || token.type.control?) && token.suppress_leading?
          char_index = string.rindex('\n')
          char_index = char_index ? char_index + 1 : 0
          byte_index = string.char_index_to_byte_index(char_index).not_nil!
          reader = Char::Reader.new(string)
          reader.pos = byte_index
          while reader.current_char.ascii_whitespace? && reader.has_next?
            reader.next_char
          end
          string = string.byte_slice(0, byte_index) if reader.pos == string.bytesize
        end
        string
      end

      private def suppress_trailing_whitespace(token, suppress_trailing)
        if suppress_trailing && token.type.string?
          newline_index = token.value.index('\n')
          token.value = token.value[newline_index + 1..-1] if newline_index
        end
      end

      private def append_location(output, filename, line_number, column_number, parenthesized = false)
        output << "#<loc:push>"
        output << '(' if parenthesized
        append_source_location(output, filename, line_number, column_number)
      end

      private def append_source_location(output, filename, line_number, column_number)
        output << "#<loc:"
        filename.inspect(output)
        output << ',' << line_number.to_s << ',' << column_number.to_s << '>'
      end
    end
  end
end

if ARGV.size < 1
  STDERR.puts "usage: caramel/view/compiler TEMPLATE [BUFFER]"
  exit 1
end

buffer_name = ARGV[1]? || Caramel::View::Compiler::DefaultBufferName
puts Caramel::View::Compiler.process_file(ARGV[0], buffer_name)
