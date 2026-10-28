# Policies, compensations and their Cold Brew jobs, renamed jobs included.
module SweetTalk
  # One `whenever`: a typed handler, in a transaction or, for a projection or a process,
  # its unit of work; a filter that `SweetTalk.dispatch` calls with every event; and the
  # Cold Brew job that runs the handler as the event's actor, and its compensation when
  # the handler is refused. The block arrives as written, so errors point at its lines.
  # With `each:` the filter enqueues one job per element of the event's list, and the
  # handler receives the element too. In a process, `key:` picks the row the block runs
  # on. `attempts:`, `backoff:` and `base:` are the job's retry rule for any error but a
  # refusal or a boundary, which fail it at once; Cold Brew checks the literals. The job
  # is named after its owner (the context and its border, the projection or the process)
  # and the event's path, because `caramel_jobs` stores the name.
  macro __sweettalk_policy(scope, event, each, border, kind, key, attempts, backoff, base,
                           *arguments, &block)
    {% type = scope.resolve %}
    {% owner = border ? "#{border.names.last}Border".id : nil %}
    {% job = "When#{event.names.join("").id}".id %}
    {% path = owner ? "#{owner}::#{job}".id : job %}
    {% prefix = owner ? [owner.underscore] : [] of Nil %}
    {% suffix = (prefix + event.names.map(&.stringify.underscore)).join("_").id %}
    {% home = owner ? (type.has_constant?(owner) && type.constant(owner)) : type %}
    {% if home && home.has_constant?(job) %}
      {% place = border ? " in border #{border}" : "" %}
      {% event.raise "#{type.name.split("::").last.id} already handles #{event}" +
                     "#{place.id}; write one whenever per event" %}
    {% end %}
    {% if each && arguments.size != 2 %}
      {% event.raise "whenever #{event}, each: #{each} takes two block arguments, the event and " +
                     "one element, as in do |#{event.names.last.underscore.id}, item|" %}
    {% end %}
    {% named = arguments.empty? ? ["event".id] : arguments %}
    {% parameters = "#{named[0]} : #{event}" + (each ? ", #{named[1]}" : "") %}
    {% names = each ? "#{named[0]}, #{named[1]}" : "#{named[0]}" %}
    {% compensation = "__sweettalk_compensate_#{suffix}" %}
    {% handler = border ? "border #{border}" : type.name.split("::").last %}
    {% if kind == "process" %}
      # The row this step runs on.
      def self.__sweettalk_key_{{ suffix }}({{ parameters.id }})
        {{ key }}
      end

      protected def __sweettalk_step_{{ suffix }}({{ parameters.id }}) : Nil
        {{ block.body }}
      end
    {% end %}

    def self.__sweettalk_on_{{ suffix }}({{ parameters.id }}) : Nil
      ::SweetTalk.__sweettalk_handling("a whenever handler", "use each: or a second whenever") do
        {% if kind == "process" %}
          ::SweetTalk.__sweettalk_unit do
            row = self[__sweettalk_key_{{ suffix }}({{ names.id }})]
            row.__sweettalk_step_{{ suffix }}({{ names.id }})
          end
        {% elsif kind == "projection" %}
          ::SweetTalk.__sweettalk_unit do
            {{ block.body }}
          end
        {% else %}
          ::SugarORM::Repo.transaction do
            {{ block.body }}
          end
        {% end %}
      end
    end

    def self.__sweettalk_enqueue_{{ suffix }}(event : ::SweetTalk::Event) : Nil
      return unless event.is_a?({{ event }})
      subject, fields, meta = event.__sweettalk_subject_id, event.__sweettalk_fields,
        event.__sweettalk_meta
      {% if each %}
        event.{{ each.id }}.size.times do |index|
          {{ path }}.enqueue(subject: subject, fields: fields, meta: meta, index: index)
        end
      {% else %}
        {{ path }}.enqueue(subject: subject, fields: fields, meta: meta)
      {% end %}
    end

    {% if owner %}module {{ owner }}{% end %}
    struct {{ job }} < ::Caramel::ColdBrew::Job
      param subject : Int64? = nil
      param fields : String
      param meta : String
      {% if each %}
        param index : Int32
      {% end %}
      retry_on ::SweetTalk::Refusal, attempts: 1
      retry_on ::SweetTalk::Boundary, attempts: 1
      ::SweetTalk.__sweettalk_retries({{ attempts }}, {{ backoff }}, {{ base }})

      # Once every name is known: the job's old name, when a rename changed it, and the
      # check that a tenanted handler does not follow a central event.
      macro finished
        ::SweetTalk.__sweettalk_aliased(\{{ @type.name.stringify }},
          \{{ {{ event }}.resolve.name.stringify }}, {{ event.names.size }})
        ::SweetTalk.__sweettalk_tenancy_of(\{{ @type.name.stringify }},
          \{{ {{ event }}.resolve.name.stringify }}, {{ event.stringify }}, {{ handler }})
      end

      def perform
        ::SweetTalk.__sweettalk_checked
        {% if each %}
          \{% begin %}
            \{% list = {{ event }}.resolve.instance_vars
                 .find { |var| var.name.stringify == {{ each.id.stringify }} } %}
            \{% unless list && list.type.name(generic_args: false).stringify == "Array" %}
              \{% raise "whenever {{ event }}, each: {{ each }} needs a list, " +
                       "but {{ event }} has no Array field named {{ each.id }}" %}
            \{% end %}
          \{% end %}
        {% end %}
        event = {{ event }}.__sweettalk_load(subject, fields, meta)
        arguments = {% if each %}{event, event.{{ each.id }}[index]}{% else %}{event}{% end %}
        ::SweetTalk.__sweettalk_following(event.actor, event.event_id, event.flow_id) do
          begin
            ::{{ type }}.__sweettalk_on_{{ suffix }}(*arguments)
          rescue refusal : ::SweetTalk::Refusal
            \{% if ::{{ type }}.class.has_method?({{ compensation }}) %}
              ::{{ type }}.__sweettalk_compensate_{{ suffix }}(*arguments, refusal)
            \{% else %}
              raise refusal
            \{% end %}
          end
        end
      end
    end
    {% if owner %}end{% end %}
  end

  # The retry rule a `whenever` or a `deadline` declares with `attempts:`, `backoff:` and
  # `base:`, in a generated job's body after the two refusal rules, so a refusal or a
  # boundary still fails at once. With none given, Cold Brew's default rule applies.
  macro __sweettalk_retries(attempts, backoff, base)
    {% if attempts || backoff || base %}
      {% rule = [] of Nil %}
      {% rule << "attempts: #{attempts}" if attempts %}
      {% rule << "backoff: #{backoff}" if backoff %}
      {% rule << "base: #{base}" if base %}
      retry_on ::Exception, {{ rule.join(", ").id }}
    {% end %}
  end

  # One `compensate`: what to do when the handler of the `whenever` before it for the same
  # event is refused. The handler's work has rolled back by then; the compensation gets
  # the handler's arguments and the refusal, and runs in its own handling and its own
  # transaction, or, in a process, its own unit on the same row. A refusal here fails the
  # job.
  macro __sweettalk_compensation(scope, event, border, kind, *arguments, &block)
    {% type = scope.resolve %}
    {% owner = border ? "#{border.names.last}Border".id : nil %}
    {% job = "When#{event.names.join("").id}".id %}
    {% prefix = owner ? [owner.underscore] : [] of Nil %}
    {% suffix = (prefix + event.names.map(&.stringify.underscore)).join("_").id %}
    {% home = owner ? (type.has_constant?(owner) ? type.constant(owner) : nil) : type %}
    {% unless home && home.has_constant?(job) %}
      {% event.raise "compensate #{event} needs a whenever #{event} before it in " +
                     "#{(owner || type.name.split("::").last).id}" %}
    {% end %}
    {% unless arguments.size == 2 || arguments.size == 3 %}
      {% event.raise "compensate #{event} takes the whenever's block arguments and the refusal, " +
                     "as in do |#{event.names.last.underscore.id}, refusal|" %}
    {% end %}
    {% refusal = arguments[arguments.size - 1] %}
    {% item = arguments.size == 3 ? ", #{arguments[1]}" : "" %}
    {% parameters = "#{arguments[0]} : #{event}#{item.id}, #{refusal} : ::SweetTalk::Refusal" %}
    {% names = "#{arguments[0]}#{item.id}" %}
    def self.__sweettalk_compensate_{{ suffix }}({{ parameters.id }}) : Nil
      ::SweetTalk.__sweettalk_handling("a compensation", ::SweetTalk::INSTEAD) do
        {% if kind == "process" %}
          ::SweetTalk.__sweettalk_unit do
            row = self[__sweettalk_key_{{ suffix }}({{ names.id }})]
            row.__sweettalk_undo_{{ suffix }}({{ names.id }}, {{ refusal }})
          end
        {% else %}
          ::SugarORM::Repo.transaction do
            {{ block.body }}
          end
        {% end %}
      end
    end

    {% if kind == "process" %}
      protected def __sweettalk_undo_{{ suffix }}({{ parameters.id }}) : Nil
        {{ block.body }}
      end
    {% end %}
  end

  # Refuses, in a program that requires caramel/tenancy, a `whenever` in a tenanted
  # context for an event of a central one (ADR 0033): the event carries no tenant, so the
  # handler would fail, or write into whichever tenant the command happened to run in.
  # *job* and *event* are full type names; *written* is the event's path as written, and
  # *handler* the projection, process, context or border that holds the `whenever`.
  macro __sweettalk_tenancy_of(job, event, written, handler)
    {% if ::Caramel.has_constant?("Tenancy") %}
      {% contexts = ::SweetTalk::BoundedContext.includers %}
      {% source = contexts.find { |context| event.starts_with?("#{context.name}::") } %}
      {% owner = contexts.find { |context| job.starts_with?("#{context.name}::") } %}
      {% if source && owner && source.constant("SWEETTALK_CENTRAL") &&
              !owner.constant("SWEETTALK_CENTRAL") %}
        {% central = source.name.split("::").last %}
        {% raise "whenever #{written.id} in #{handler.id}: #{central.id} is central, so its " +
                 "events carry no tenant, and #{owner.name.split("::").last.id}'s rows belong " +
                 "to one; handle it in a central context, or drop central: true from " +
                 "#{central.id}" %}
      {% end %}
    {% end %}
  end

  # Declares Cold Brew's `renamed_from` on a generated job when a rename changed its
  # name. Each part of *job*'s path that comes from a renamed context, border,
  # projection or process takes its old name, and so does each segment of the event's
  # path as written, the last *count* parts of *event*; so a job queued under the old
  # name runs as this one.
  macro __sweettalk_aliased(job, event, count)
    {% names = job.split("::") %}
    {% old = [] of Nil %}
    {% for name, index in names %}
      {% if index < names.size - 1 %}
        {% here = parse_type("::" + names[0..index].join("::")).resolve %}
        {% was = here.has_constant?("SWEETTALK_WAS") ? here.constant("SWEETTALK_WAS") : nil %}
        {% if was %}
          {% old << was %}
        {% elsif name.ends_with?("Border") && index > 1 %}
          {% other = parse_type("::" + (names[0..index - 2] + [name[0..-7]]).join("::")).resolve? %}
          {% renamed = other && other.has_constant?("SWEETTALK_WAS") %}
          {% before = renamed && other.constant("SWEETTALK_WAS") %}
          {% old << (before ? before + "Border" : name) %}
        {% else %}
          {% old << name %}
        {% end %}
      {% end %}
    {% end %}
    {% if event %}
      {% full = event.split("::") %}
      {% segments = [] of Nil %}
      {% for index in (full.size - count)...full.size %}
        {% here = parse_type("::" + full[0..index].join("::")).resolve %}
        {% was = here.has_constant?("SWEETTALK_WAS") ? here.constant("SWEETTALK_WAS") : nil %}
        {% segments << (was ? was : full[index]) %}
      {% end %}
      {% old << "When" + segments.join("") %}
    {% else %}
      {% old << names.last %}
    {% end %}
    {% if old.join("::") != job %}
      renamed_from {{ old.join("::") }}
    {% end %}
  end
end
