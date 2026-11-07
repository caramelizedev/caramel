# The public read of a lifecycle's graph (ADR 0058).
module SweetTalk
  module Lifecycle
    # Writes `Order.moves_from(state)` and `order.may_become?(state)` from the states of
    # `moves` and, for each later state, the states just before it in a chain (nil when
    # there is none). The movers stay private: these only read the graph, so a screen offers
    # what may come next, and a `case … in` over the states fails compilation when a state
    # is added.
    macro __sweettalk_graph(states, before)
      {% before = {} of Nil => Nil if before.is_a?(NilLiteral) %}
      # The states a mover may enter from *state*, in the order `moves` first names them.
      def self.moves_from(state : State) : Array(State)
        case state
        {% for name in states %}
          {% nexts = states.select { |later| before[later] && before[later].includes?(name) } %}
        in State::{{ name.camelcase.id }}
          [{{ nexts.map { |later| "State::#{later.camelcase.id}".id }.splat }}] of State
        {% end %}
        end
      end

      # Whether a mover may enter *state* from the current one.
      def may_become?(state : State) : Bool
        case state
        {% for name in states %}
          {% sources = before[name] || [] of Nil %}
          {% sources = sources.map { |source| "@state == State::#{source.camelcase.id}" } %}
        in State::{{ name.camelcase.id }}
          {{ sources.empty? ? false : sources.join(" || ").id }}
        {% end %}
        end
      end
    end
  end
end
