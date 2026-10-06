require "pretty_print"
require "../crema"

module Caramel::Crema
  # `dump value` prints a value and where it was dumped, and returns the value
  # so it can sit inside an expression. It is a development aid: in a
  # production binary, or when `CARAMEL_ENV` is not `development`, it returns
  # the value untouched. Inside a recording trace the dump also joins the
  # request's inspector page. `frappe lint` reports a `dump` left in the code.
  module Dumping
    MAX_DUMP = 8192

    def dump(value : T, file : String = __FILE__, line : Int32 = __LINE__) : T forall T
      Dumping.record(value, file, line)
      value
    end

    {% if flag?(:caramel_development) %}
      # :nodoc:
      def self.record(value, file : String, line : Int32) : Nil
        return unless Crema.development?

        where = "#{Frames.relative(file, Frames.root)}:#{line}"
        text = value.pretty_inspect
        STDERR.puts "dump #{where}: #{text}"
        trace = Crema.current? || return
        trace.open_span(SpanKind::Dump, where, text.byte_slice(0, MAX_DUMP).scrub, Time.instant)
      end
    {% else %}
      # :nodoc:
      def self.record(value, file : String, line : Int32) : Nil
      end
    {% end %}
  end
end

module Caramel
  # See `Caramel::Crema::Dumping`.
  def self.dump(value : T, file : String = __FILE__, line : Int32 = __LINE__) : T forall T
    Crema::Dumping.record(value, file, line)
    value
  end
end
