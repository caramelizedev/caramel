# The words of SweetTalk's modules (ADR 0061), as the core sees them: each fails
# compilation naming the require that defines it, and the module's file redefines it.
module SweetTalk
  module BoundedContext
    macro currencies(codes, exponent = nil, means = nil)
      {% raise "currencies needs require \"caramel/sweet_talk/money\" before this domain: a " +
               "program that declares no currency holds none of its code" %}
    end

    macro quote(name, rounding = nil, means = nil)
      {% raise "quote needs require \"caramel/sweet_talk/money\" before this domain: a " +
               "program that declares no currency holds none of its code" %}
    end

    macro allocation(name, of = nil, by = nil, remainder = nil, ties = nil, means = nil,
                     per = nil, &block)
      {% raise "allocation needs require \"caramel/sweet_talk/money\" before this domain: a " +
               "program that declares no currency holds none of its code" %}
    end
  end
end
