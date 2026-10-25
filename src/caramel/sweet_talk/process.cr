# Process managers: steps, compensations and deadlines on one row per key.
module SweetTalk
  # A process manager: a row per key that follows events from any context, moves
  # through its own lifecycle, runs one aggregate's command per step, compensates a
  # refused step, and keeps deadlines. Its steps run in units of work, as a projection's
  # handlers do, and changing its own row does not count toward the one aggregate a step
  # may change.
  abstract class Process < Model
    include Keyed
    include Lifecycle

    # `key slot : Slot` names the attribute that picks a row.
    macro key(decl)
      SWEETTALK_KEY = {{ decl.var.stringify }}

      has {{ decl }}
    end

    # `whenever Order::Placed, each: :lines, key: Slot.new(…) do |placed, line| … end` is
    # a step: the job finds the row that `key:` picks, inserting it in its first state
    # when absent, and runs the block on it.
    macro whenever(event, key = nil, each = nil, &block)
      {% process = @type.name.split("::").last %}
      {% if key.is_a?(NilLiteral) %}
        {% event.raise "whenever #{event} in process #{process.id} needs key:, " +
                       "the expression that picks its row" %}
      {% end %}
      __sweettalk_no_stray_writes({{ "whenever #{event}" }}, {{ block.body.stringify }})
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, nil, "process",
        {{ key }}, {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # `compensate Order::Placed do |placed, line, refusal| … end` runs on the same row
    # when the step for that event is refused.
    macro compensate(event, &block)
      __sweettalk_no_stray_writes({{ "compensate #{event}" }}, {{ block.body.stringify }})
      ::SweetTalk.__sweettalk_compensation({{ @type }}, {{ event }}, nil, "process",
        {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # `deadline lapse, after: 7.days do … end` is a timer on each row: `arm lapse` sets
    # it to fire after the span, or `arm lapse, after: 2.days` after another one,
    # `disarm lapse` cancels it, and `lapse_due` tells when it fires. Each arming
    # enqueues a job to run at that time; the job runs the block only if no arming or
    # disarming came after its own, which an arming counter tells.
    macro deadline(name, after = nil, &block)
      {% process = @type.name.split("::").last %}
      {% job = "#{name.id.camelcase}Deadline".id %}
      SWEETTALK_DEADLINE_{{ name.id.upcase }} = { {{ name.id.stringify }}, {{ name.line_number }} }

      has {{ name.id }}_arming : Int32 = 0
      has {{ name.id }}_due : Time?

      protected def __sweettalk_arm_{{ name.id }}(span : Time::Span = ({{ after }})) : Nil
        @{{ name.id }}_arming += 1
        due = Time.utc + span
        @{{ name.id }}_due = due
        fiber = ::Fiber.current
        {{ job }}.enqueue(key: __sweettalk_key_json, arming: @{{ name.id }}_arming, run_at: due,
          cause: fiber.__sweettalk_cause, flow: fiber.__sweettalk_flow)
      end

      protected def __sweettalk_disarm_{{ name.id }} : Nil
        @{{ name.id }}_arming += 1
        @{{ name.id }}_due = nil
      end

      # Clears the due time, then runs the deadline's block on this row.
      def __sweettalk_fire_{{ name.id }} : Nil
        @{{ name.id }}_due = nil
        __sweettalk_deadline_{{ name.id }}
      end

      __sweettalk_no_stray_writes({{ "deadline #{name.id}" }}, {{ block.body.stringify }})
      private def __sweettalk_deadline_{{ name.id }} : Nil
        {{ block.body }}
      end

      struct {{ job }} < ::Caramel::ColdBrew::Job
        param key : String
        param arming : Int32
        param cause : String? = nil
        param flow : String? = nil
        retry_on ::SweetTalk::Refusal, attempts: 1
        retry_on ::SweetTalk::Boundary, attempts: 1

        # Once every name is known: the job's old name, when a rename changed it.
        macro finished
          ::SweetTalk.__sweettalk_aliased(\{{ @type.name.stringify }}, nil, 0)
        end

        def perform
          ::SweetTalk.__sweettalk_checked
          by = {{ "deadline #{process.id}.#{name.id}" }}
          ::SweetTalk.__sweettalk_following(by, cause, flow) do
            ::SweetTalk.__sweettalk_handling("a deadline", ::SweetTalk::INSTEAD) do
              ::SweetTalk.__sweettalk_unit do
                row = ::{{ @type }}[::{{ @type }}.__sweettalk_key_from(key)]
                row.__sweettalk_fire_{{ name.id }} if row.{{ name.id }}_arming == arming
              end
            end
          end
        end
      end
    end

    # `arm lapse` sets the deadline to fire after its span from now, and
    # `arm lapse, after: 2.days` after that span instead.
    macro arm(name, after = nil)
      \{% unless @type.has_constant?({{ "SWEETTALK_DEADLINE_#{name.id.upcase}" }}) %}
        \{% deadlines = @type.constants.select(&.starts_with?("SWEETTALK_DEADLINE_"))
             .map { |constant| @type.constant(constant)[0] }.join(", ") %}
        \{% raise {{ "arm #{name.id} names no deadline of " }} + @type.name.split("::").last +
                 "; deadlines: " + deadlines +
                 {{ "\n  --> #{name.filename.id}:#{name.line_number}:#{name.column_number}" }} %}
      \{% end %}
      __sweettalk_arm_{{ name.id }}{% unless after.is_a?(NilLiteral) %}({{ after }}){% end %}
    end

    # `disarm lapse` cancels the deadline.
    macro disarm(name)
      \{% unless @type.has_constant?({{ "SWEETTALK_DEADLINE_#{name.id.upcase}" }}) %}
        \{% deadlines = @type.constants.select(&.starts_with?("SWEETTALK_DEADLINE_"))
             .map { |constant| @type.constant(constant)[0] }.join(", ") %}
        \{% raise {{ "disarm #{name.id} names no deadline of " }} + @type.name.split("::").last +
                 "; deadlines: " + deadlines +
                 {{ "\n  --> #{name.filename.id}:#{name.line_number}:#{name.column_number}" }} %}
      \{% end %}
      __sweettalk_disarm_{{ name.id }}
    end

    # Rows, loading and saving, from the attributes declared so far.
    macro __sweettalk_storage
      ::SweetTalk.__sweettalk_keyed({{ @type }})
    end
  end
end
