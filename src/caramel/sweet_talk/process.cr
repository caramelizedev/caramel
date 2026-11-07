# Process managers: steps, compensations and deadlines on one row per key.
module SweetTalk
  # A process manager: a row per key that follows events from any context, moves
  # through its own lifecycle, runs one aggregate's command per step, compensates a
  # refused step, keeps deadlines, and declares `finds` and `counts` over its rows as a
  # projection does. Its steps run in units of work, as a projection's handlers do, and
  # changing its own row does not count toward the one aggregate a step may change.
  abstract class Process < Model
    include Keyed
    include Lifecycle
    include Queried

    # `key slot : Slot` names the attribute that picks a row.
    #
    # @word attribute | Names the attribute that picks a row of a process, and declares it.
    # @usage key NAME : TYPE
    # @guide c-sweettalk-processes
    # @example
    #   context Quay, means: "ships at a quay" do
    #     process Berth, means: "the berth held for one ship" do
    #       key ship : Int64
    #       has days : Int32 = 0
    #     end
    #   end
    macro key(decl)
      SWEETTALK_KEY = {{ decl.var.stringify }}

      has {{ decl }}
    end

    # `whenever Order::Placed, each: :lines, key: Slot.new(…) do |placed, line| … end` is
    # a step: the job finds the row that `key:` picks, inserting it in its first state
    # when absent, and runs the block on it. `attempts:`, `backoff:` and `base:` set the
    # job's retry rule, and `after: Owner` runs the job once the named owner's handler of
    # the same event has committed.
    #
    # @word behaviour | Runs a step of a process when an event happens, on the row its key picks.
    # @usage whenever EVENT, key: EXPRESSION[, each: LIST][, attempts: N][, backoff: KIND]
    #   [, base: SPAN][, after: OWNER] do |EVENT_VAR| ... end
    # @option key | expression over the block's arguments | - | Picks the row the step runs on;
    #   the row is inserted in its first state when absent. Required.
    # @option each | symbol naming an Array field of the event | - | Runs one job per element of
    #   the list; the block takes the element as a second argument.
    # @option attempts | integer literal | Cold Brew's default rule | How many runs the job gets,
    #   the first included, for an error other than a refusal.
    # @option backoff | :exponential or :linear | Cold Brew's default rule | How the wait between
    #   runs grows.
    # @option base | a span, as 2.seconds | Cold Brew's default rule | The wait the backoff starts
    #   from.
    # @option after | name of a projection, process or context | - | Runs the job once that
    #   owner's handler of the same event has committed.
    # @guide c-sweettalk-processes
    # @example
    #   context Wharf, means: "ships arriving at a wharf" do
    #     aggregate Ship, means: "a vessel that asks for a berth" do
    #       has name : String
    #       event Arrived, means: "a ship reached the wharf"
    #
    #       factory arrive(name : String) do
    #         emit Arrived
    #       end
    #     end
    #
    #     process Berth, means: "the berth held for one arrived ship" do
    #       key ship : Int64
    #       has days : Int32 = 0
    #       moves waiting >> held
    #
    #       whenever Ship::Arrived, key: arrived.ship_id.raw, attempts: 5 do |arrived|
    #         @days = 1
    #         held!
    #       end
    #     end
    #   end
    macro whenever(event, key = nil, each = nil, attempts = nil, backoff = nil, base = nil,
                   after = nil, &block)
      {% process = @type.name.split("::").last %}
      {% if key.is_a?(NilLiteral) %}
        {% event.raise "whenever #{event} in process #{process.id} needs key:, " +
                       "the expression that picks its row" %}
      {% end %}
      __sweettalk_no_stray_writes({{ "whenever #{event}" }}, {{ block.body.stringify }})
      ::SweetTalk.__sweettalk_policy({{ @type }}, {{ event }}, {{ each }}, nil, "process",
        {{ key }}, {{ attempts }}, {{ backoff }}, {{ base }}, {{ after }},
        {{ block.args.splat }}) do
        {{ block.body }}
      end
    end

    # `compensate Order::Placed do |placed, line, refusal| … end` runs on the same row
    # when the step for that event is refused.
    #
    # @word behaviour | Runs on the same row when the step for an event is refused.
    # @usage compensate EVENT do |EVENT_VAR, REFUSAL| ... end
    # @in in a process, after the whenever for the same event
    # @guide c-sweettalk-processes
    # @example
    #   context Jetty, means: "ships that ask for a jetty" do
    #     aggregate Skiff, means: "a boat that asks for a jetty" do
    #       has name : String
    #       event Called, means: "a skiff asked for the jetty"
    #
    #       factory call(name : String) do
    #         emit Called
    #       end
    #     end
    #
    #     process Slot, means: "the jetty place for one skiff" do
    #       key skiff : Int64
    #       moves waiting >> held, waiting >> refused
    #
    #       whenever Skiff::Called, key: called.skiff_id.raw do |called|
    #         held!
    #       end
    #
    #       compensate Skiff::Called do |called, refusal|
    #         refused!
    #       end
    #     end
    #   end
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
    # disarming came after its own, which an arming counter tells. `attempts:`,
    # `backoff:` and `base:` set the job's retry rule.
    #
    # @word behaviour | Declares a timer on each row of a process that runs its block when it fires.
    # @usage deadline NAME[, after: SPAN][, attempts: N][, backoff: KIND][, base: SPAN] do ... end
    # @option after | a span, as 7.days | - | The span `arm NAME` waits when it names none. Needed
    #   when any `arm NAME` has no `after:`.
    # @option attempts | integer literal | Cold Brew's default rule | How many runs the job gets,
    #   the first included, for an error other than a refusal.
    # @option backoff | :exponential or :linear | Cold Brew's default rule | How the wait between
    #   runs grows.
    # @option base | a span, as 2.seconds | Cold Brew's default rule | The wait the backoff starts
    #   from.
    # @guide c-sweettalk-processes
    # @example
    #   context Boatyard, means: "ships waiting in a dock" do
    #     aggregate Barge, means: "a barge that asks for a dock" do
    #       has name : String
    #       event Moored, means: "a barge reached the dock"
    #
    #       factory moor(name : String) do
    #         emit Moored
    #       end
    #     end
    #
    #     process Stay, means: "the dock held for one moored barge" do
    #       key barge : Int64
    #       moves waiting >> holding >> released
    #
    #       whenever Barge::Moored, key: moored.barge_id.raw do |moored|
    #         holding!
    #         arm lapse
    #       end
    #
    #       deadline lapse, after: 7.days, attempts: 3, backoff: :linear, base: 2.seconds do
    #         released! if holding?
    #       end
    #     end
    #   end
    macro deadline(name, after = nil, attempts = nil, backoff = nil, base = nil, &block)
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
        ::SweetTalk.__sweettalk_retries({{ attempts }}, {{ backoff }}, {{ base }})

        # Once every name is known: the job's old name, when a rename changed it.
        macro finished
          ::SweetTalk.__sweettalk_aliased(\{{ @type.name.stringify }}, nil, 0)
        end

        def perform
          ::SweetTalk.__sweettalk_checked
          by = {{ "deadline #{process.id}.#{name.id}" }}
          ::SweetTalk.__sweettalk_following(by, cause, flow) do
            ::SweetTalk.__sweettalk_handling("a deadline", ::SweetTalk::INSTEAD) do
              ::SweetTalk.__sweettalk_work do
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
    #
    # @word behaviour | Sets a deadline of this process row to fire after its span from now.
    # @usage arm NAME[, after: SPAN]
    # @in in a step, a compensation or a deadline of a process
    # @option after | a span, as 2.days | the span the deadline declares | How long from now the
    #   deadline fires. Arming again replaces the earlier arming.
    # @guide c-sweettalk-processes
    # @example
    #   context Mooring, means: "ships tied up at a mooring" do
    #     aggregate Vessel, means: "a ship that asks for a mooring" do
    #       has name : String
    #       event Tied, means: "a vessel was tied up"
    #
    #       factory tie(name : String) do
    #         emit Tied
    #       end
    #     end
    #
    #     process Line, means: "the line held for one tied vessel" do
    #       key vessel : Int64
    #       moves slack >> taut >> cast_off
    #
    #       whenever Vessel::Tied, key: tied.vessel_id.raw do |tied|
    #         taut!
    #         arm cast, after: 2.days
    #       end
    #
    #       deadline cast, after: 7.days do
    #         cast_off! if taut?
    #       end
    #     end
    #   end
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
    #
    # @word behaviour | Cancels a deadline of this process row, so its block does not run.
    # @usage disarm NAME
    # @in in a step, a compensation or a deadline of a process
    # @guide c-sweettalk-processes
    # @example
    #   context Slipway, means: "hulls waiting for a slip" do
    #     aggregate Hull, means: "a ship on the slipway" do
    #       has name : String
    #       event Launched, means: "a hull was launched"
    #       event Withdrawn, means: "a hull was taken off the list"
    #
    #       factory lay(name : String) do
    #         emit Launched
    #       end
    #
    #       to withdraw do
    #         emit Withdrawn
    #       end
    #     end
    #
    #     process Slip, means: "the slip reserved for one launched hull" do
    #       key hull : Int64
    #       moves waiting >> reserved >> released
    #
    #       whenever Hull::Launched, key: launched.hull_id.raw do |launched|
    #         reserved!
    #         arm lapse
    #       end
    #
    #       whenever Hull::Withdrawn, key: withdrawn.hull_id.raw do |withdrawn|
    #         disarm lapse
    #         released! if reserved?
    #       end
    #
    #       deadline lapse, after: 7.days do
    #         released! if reserved?
    #       end
    #     end
    #   end
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
