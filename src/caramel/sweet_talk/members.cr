# The members of a closed-set value as a Crystal enum (ADR 0058).
module SweetTalk
  abstract struct Value
    # Writes `enum Member` for a value with `one_of:`, one member per word in the order the
    # list gives them, with `kind.member` and `Kind.new(member)` between the two. The column,
    # its check and the check's hash keep the words. A word's member is named so that its
    # predicate is the value's own: `net_settlement` is `NetSettlement`, `net_settlement?`;
    # a word whose camel case would lose an underscore, such as `x_1`, keeps it, `X_1`.
    macro __sweettalk_members(names)
      enum Member
        {% for name in names %}
          {% camel = name.camelcase %}
          {{ (camel.underscore == name ? camel : name.capitalize).id }}
        {% end %}
      end

      # This value's member, for a `case … in` that names every one.
      def member : Member
        Member.from_value(SWEETTALK_ONE_OF.index!(@raw))
      end

      # The value of *member*.
      def self.new(member : Member) : self
        new(SWEETTALK_ONE_OF[member.value])
      end
    end
  end
end
