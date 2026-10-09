require "json"
require "../../sugar_orm"
require "../crema/dump"

module Caramel::ColdBrew
  QUEUE_NAME = /\A[a-z0-9_.:-]{1,63}\z/

  class UnknownJob < Exception
    def initialize(class_name : String)
      super(<<-TEXT)
        No Caramel::ColdBrew::Job named #{class_name} is compiled into this application.
        Remediation: restore the job struct, or delete its rows from caramel_jobs.
        TEXT
    end
  end

  enum Backoff
    Exponential
    Linear
  end

  # How often a failing job runs again. `attempts` counts every run, the
  # first included; after the last one the job is marked failed.
  struct RetryRule
    getter attempts : Int32
    getter backoff : Backoff
    getter base : Time::Span

    def initialize(@matcher : Exception -> Bool,
                   @attempts : Int32,
                   @backoff : Backoff,
                   @base : Time::Span)
    end

    def matches?(error : Exception) : Bool
      @matcher.call(error)
    end

    # The wait after run number `attempt` failed: `base * 2**(attempt - 1)`
    # or `base * attempt`.
    def delay(attempt : Int32) : Time::Span
      case @backoff
      in .exponential? then @base * (2_i64 ** (attempt - 1).clamp(0, 30))
      in .linear?      then @base * attempt
      end
    end
  end

  module Retry
    DEFAULT = RetryRule.new(->(_error : Exception) { true }, 3, Backoff::Exponential, 1.second)
    GLOBAL  = "Caramel::ColdBrew::Job"

    @@rules = {} of String => Array(RetryRule)

    def self.register(owner : String, rule : RetryRule) : Nil
      (@@rules[owner] ||= [] of RetryRule) << rule
    end

    # The first matching rule declared on the job or its abstract parents,
    # then the first global one, then 3 exponential attempts from 1 second.
    def self.rule_for(lineage : Array(String), error : Exception) : RetryRule
      lineage.each do |owner|
        if rule = @@rules[owner]?.try(&.find(&.matches?(error)))
          return rule
        end
      end
      @@rules[GLOBAL]?.try(&.find(&.matches?(error))) || DEFAULT
    end
  end

  # A background job. Its params are the JSON payload stored in
  # `caramel_jobs`; `enqueue` writes the row through SugarORM::Repo's current
  # connection, so inside `Repo.transaction` it commits or rolls back with
  # the business write.
  #
  #     struct SendInvitation < Caramel::ColdBrew::Job
  #       queue "mailers"
  #       retry_on Stripe::RateLimitError, attempts: 5, backoff: :exponential, base: 2.seconds
  #       param invite_id : Int64
  #
  #       def perform
  #       end
  #     end
  #
  #     SendInvitation.enqueue(invite_id: 42, run_at: 10.minutes.from_now, priority: 5) # => job id
  abstract struct Job
    include Crema::Dumping
    include JSON::Serializable

    abstract def perform

    def self.queue_name : String
      "default"
    end

    macro queue(name)
      {% at = "\n  --> #{name.filename.id}:#{name.line_number}:#{name.column_number}" %}
      {% unless name.is_a?(StringLiteral) && name =~ /\A[a-z0-9_.:-]{1,63}\z/ %}
        {% message = "queue expects a literal name of 1-63 characters from [a-z0-9_.:-].\n" \
                     "Remediation: write it like `queue \"mailers\"`." %}
        {% name.raise message + at %}
      {% end %}
      {% if @type.has_constant?(:COLD_BREW_QUEUE) %}
        {% message = "#{@type} declares its queue twice.\nRemediation: keep one `queue` line." %}
        {% name.raise message + at %}
      {% end %}
      COLD_BREW_QUEUE = {{ name }}

      def self.queue_name : String
        {{ name }}
      end
    end

    # Declares a typed payload field and its getter; `= default` makes the
    # `enqueue` keyword optional.
    macro param(declaration)
      {% at = "\n  --> #{declaration.filename.id}:" \
              "#{declaration.line_number}:#{declaration.column_number}" %}
      {% unless declaration.is_a?(TypeDeclaration) %}
        {% message = "param expects `param name : Type`, optionally with `= default`.\n" \
                     "Remediation: write it like `param invite_id : Int64`." %}
        {% declaration.raise message + at %}
      {% end %}
      {% name = declaration.var.id %}
      {% if %w[run_at priority].includes?(name.stringify) %}
        {% message = "param '#{name}' collides with enqueue's own `#{name}:` keyword.\n" \
                     "Remediation: rename the param, " \
                     "for example `param #{name}_value : #{declaration.type}`." %}
        {% declaration.raise message + at %}
      {% end %}
      {% if name.stringify == "caramel_tenant" %}
        {% message = "param 'caramel_tenant' is reserved for the tenant " \
                     "caramel/tenancy carries.\nRemediation: rename the param." %}
        {% declaration.raise message + at %}
      {% end %}
      {% constant = "COLD_BREW_PARAM_#{name.stringify.upcase.id}".id %}
      {% if @type.has_constant?(constant) %}
        {% message = "param '#{name}' is declared twice in #{@type}.\n" \
                     "Remediation: remove the duplicate `param #{name}`." %}
        {% declaration.raise message + at %}
      {% end %}
      {% default = declaration.value.is_a?(Nop) ? nil : declaration.value.stringify %}
      # {name, type, default source or nil}
      {{ constant }} = { {{ name.stringify }}, {{ declaration.type.stringify }}, {{ default }} }

      getter {{ name }} : {{ declaration.type }}
    end

    # Names the classes this job used to have. A row queued under one of them
    # runs this job with its stored params, so a rename or a move keeps the
    # work already queued. List every old name in one call, and keep them
    # until `Caramel::ColdBrew.unknown_queued_class_names` no longer shows
    # them. A name that is another job's name or alias fails to compile.
    #
    #     struct RestockTea < Caramel::ColdBrew::Job
    #       renamed_from "App::Restock"
    #     end
    macro renamed_from(*names)
      {% if @type.abstract? %}
        {% message = "renamed_from is declared on abstract #{@type}, which no row can name.\n" \
                     "Remediation: declare it on the concrete job that replaced the old class." %}
        {% if names.empty? %}
          {% @type.raise message %}
        {% else %}
          {% first = names.first %}
          {% first.raise message + "\n  --> #{first.filename.id}:" \
                                   "#{first.line_number}:#{first.column_number}" %}
        {% end %}
      {% end %}
      {% if names.empty? %}
        {% @type.raise "renamed_from expects the old class names.\n" \
                       "Remediation: write it like `renamed_from \"App::Restock\"`." %}
      {% end %}
      {% if @type.has_constant?(:COLD_BREW_RENAMED_FROM) %}
        {% first = names.first %}
        {% at = "\n  --> #{first.filename.id}:#{first.line_number}:#{first.column_number}" %}
        {% message = "#{@type} declares renamed_from twice.\n" \
                     "Remediation: list every old name in one `renamed_from` line." %}
        {% first.raise message + at %}
      {% end %}
      {% for name in names %}
        {% at = "\n  --> #{name.filename.id}:#{name.line_number}:#{name.column_number}" %}
        {% unless name.is_a?(StringLiteral) && name =~ /\A[A-Z]\w*(::[A-Z]\w*)*\z/ %}
          {% message = "renamed_from expects the old class names as string literals " \
                       "like \"App::Restock\", without a leading ::.\n" \
                       "Remediation: write it like `renamed_from \"App::Restock\"`." %}
          {% name.raise message + at %}
        {% end %}
        {% if names.select { |other| other == name }.size > 1 %}
          {% name.raise "renamed_from lists #{name} twice in #{@type}.\n" \
                        "Remediation: keep one of them." + at %}
        {% end %}
      {% end %}
      COLD_BREW_RENAMED_FROM = { {{ names.splat }} }
    end

    # Fails to compile when a name this job claims is its own, another job's
    # name or another job's alias.
    macro __cold_brew_check_names
      {% if @type.has_constant?(:COLD_BREW_RENAMED_FROM) %}
        {% jobs = ::Caramel::ColdBrew::Job.all_subclasses.reject(&.abstract?) %}
        {% for claim in @type.constant(:COLD_BREW_RENAMED_FROM) %}
          {% at = "\n  --> #{claim.filename.id}:#{claim.line_number}:#{claim.column_number}" %}
          {% if claim == @type.name.stringify %}
            {% claim.raise "#{@type} lists its own name in renamed_from.\n" \
                           "Remediation: remove it." + at %}
          {% end %}
          {% for other in jobs.reject { |job| job == @type } %}
            {% if claim == other.name.stringify %}
              {% claim.raise "#{@type} claims #{claim} in renamed_from, " \
                             "but #{other} is a job of that name.\n" \
                             "Remediation: rename or remove one of them." + at %}
            {% end %}
            {% if other.has_constant?(:COLD_BREW_RENAMED_FROM) &&
                    other.constant(:COLD_BREW_RENAMED_FROM).any? { |old| old == claim } %}
              {% claim.raise "#{@type} and #{other} both claim #{claim} in renamed_from.\n" \
                             "Remediation: only one job can take over a name; remove it " \
                             "from the other." + at %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    # Retries matching errors; per job in its body, or for every job as
    # `Caramel::ColdBrew::Job.retry_on`. The first matching rule wins.
    macro retry_on(error, attempts = 3, backoff = :exponential, base = 1.second)
      {% at = "\n  --> #{error.filename.id}:#{error.line_number}:#{error.column_number}" %}
      {% unless error.is_a?(Path) && (type = error.resolve?) && type <= Exception %}
        {% message = "retry_on expects an exception class.\n" \
                     "Remediation: write it like `retry_on Stripe::RateLimitError, " \
                     "attempts: 5, backoff: :exponential, base: 2.seconds`." %}
        {% error.raise message + at %}
      {% end %}
      {% unless attempts.is_a?(NumberLiteral) && attempts.kind == :i32 && attempts > 0 %}
        {% message = "retry_on attempts: expects a positive integer literal " \
                     "that counts every run.\nRemediation: write `attempts: 5`." %}
        {% error.raise message + at %}
      {% end %}
      {% unless backoff.is_a?(SymbolLiteral) && (backoff == :exponential || backoff == :linear) %}
        {% message = "retry_on backoff: must be :exponential (base * 2**(attempt - 1)) " \
                     "or :linear (base * attempt)." %}
        {% error.raise message + at %}
      {% end %}
      {% if base.is_a?(NumberLiteral) %}
        {% message = "retry_on base: expects a Time::Span.\n" \
                     "Remediation: write `base: #{base}.seconds`." %}
        {% error.raise message + at %}
      {% end %}
      ::Caramel::ColdBrew::Retry.register(
        {{ @type.name.stringify }},
        ::Caramel::ColdBrew::RetryRule.new(
          ->(error : ::Exception) { error.is_a?({{ error }}) },
          {{ attempts }},
          ::Caramel::ColdBrew::Backoff::{{ backoff.id.capitalize }},
          {{ base }},
        ),
      )
    end

    macro inherited
      # The typed constructors are generated once every `param` is known, so
      # an unknown keyword or a mistyped value fails at the caller's line.
      macro finished
        \{% unless @type.abstract? %}
          __cold_brew_check_names

          \{% names = @type.constants.select(&.starts_with?("COLD_BREW_PARAM_")) %}
          \{% params = names.map { |name| @type.constant(name) } %}
          \{% keywords = params.map do |param|
                default = param[2] ? " = #{param[2].id}".id : "".id
                "#{param[0].id} : #{param[1].id}#{default}"
              end %}
          \{% arguments = params.map { |param| "#{param[0].id}: #{param[0].id}" }.join(", ") %}

          def initialize\{% unless params.empty? %}(*, \{{keywords.join(", ").id}})\{% end %}
            \{% for param in params %}
              @\{{param[0].id}} = \{{param[0].id}}
            \{% end %}
          end

          def self.enqueue(*,
                           \{% for keyword in keywords %}\{{keyword.id}}, \{% end %}
                           run_at : ::Time? = nil,
                           priority : ::Int32 = 0) : ::Int64
            ::Caramel::ColdBrew::Queue.push(
              queue_name,
              \{{@type.name.stringify}},
              new(\{{arguments.id}}).to_json,
              run_at,
              priority,
            )
          end

          def self.enqueue(db : ::SugarORM::Handle,
                           *,
                           \{% for keyword in keywords %}\{{keyword.id}}, \{% end %}
                           run_at : ::Time? = nil,
                           priority : ::Int32 = 0) : ::Int64
            ::SugarORM::Repo.using(db) do
              enqueue(
                \{% for param in params %}\{{param[0].id}}: \{{param[0].id}}, \{% end %}
                run_at: run_at,
                priority: priority,
              )
            end
          end
        \{% end %}
      end
    end

    # :nodoc:
    # The compile-time registry: every concrete job by the name it is stored
    # under in `caramel_jobs.class_name`, its current fully qualified name,
    # and by each name it declares in `renamed_from`. Returns the current
    # name, or nil when no compiled job has *class_name*.
    def self.__cold_brew_canonical(class_name : String) : String?
      {% begin %}
        case class_name
        {% for job in @type.all_subclasses.reject(&.abstract?) %}
          {% names = [job.name.stringify] %}
          {% if job.has_constant?(:COLD_BREW_RENAMED_FROM) %}
            {% for old in job.constant(:COLD_BREW_RENAMED_FROM) %}
              {% names << old %}
            {% end %}
          {% end %}
          when {{ names.splat }} then {{ job.name.stringify }}
        {% end %}
        else
          nil
        end
      {% end %}
    end

    # :nodoc:
    def self.__cold_brew_known?(class_name : String) : Bool
      !__cold_brew_canonical(class_name).nil?
    end

    # :nodoc:
    def self.__cold_brew_perform(class_name : String, payload : String) : Nil
      {% begin %}
        case __cold_brew_canonical(class_name)
        {% for job in @type.all_subclasses.reject(&.abstract?) %}
          when {{ job.name.stringify }} then {{ job }}.from_json(payload).perform
        {% end %}
        else
          raise UnknownJob.new(class_name)
        end
      {% end %}
      nil
    end

    # :nodoc:
    # The job's name and its abstract parents below Job, for retry lookup.
    def self.__cold_brew_lineage(class_name : String) : Array(String)
      {% begin %}
        case __cold_brew_canonical(class_name)
        {% for job in @type.all_subclasses.reject(&.abstract?) %}
          {% parents = job.ancestors.select { |ancestor| ancestor < @type } %}
          when {{ job.name.stringify }} then {{ ([job] + parents).map(&.name.stringify) }}
        {% end %}
        else
          [] of String
        end
      {% end %}
    end
  end
end
