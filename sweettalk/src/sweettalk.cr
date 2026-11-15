# SweetTalk, an opt-in language for Domain-Driven Design (ADR 0030).
#
# Each word is a macro. An aggregate expands into a SugarORM schema and changeset plus a
# domain class over them; a command runs in `Repo.transaction` on one aggregate; an event
# records its facts and becomes Cold Brew jobs, enqueued in that transaction, for the
# policies, projections and processes that follow it, and a PubSub notification for live
# pages. Whole-program checks are `{% %}` inside method bodies, which expand once the top
# level is complete. Requiring SweetTalk also redefines how an action answers its refusals
# (`sweettalk/action.cr`).
#
# A file of this shard requires its own files and the standard library, never the
# framework: the program requires `caramel` first (ADR 0030). One file then compiles in an
# application, where the framework is `lib/caramel`, and in the framework's repository,
# where it is `src/`, and no file is loaded by two paths.
{% unless @top_level.has_constant?("Caramel") && ::Caramel.has_constant?("CommandLine") %}
  {% raise "sweettalk needs the framework first: write require \"caramel\" before " +
           "require \"sweettalk\"" %}
{% end %}
require "uuid"
require "digest/sha256"
require "./sweettalk/errors"
require "./sweettalk/facts"
require "./sweettalk/boundary"
require "./sweettalk/value"
require "./sweettalk/members"
require "./sweettalk/specification"
require "./sweettalk/model"
require "./sweettalk/graph"
require "./sweettalk/queries"
require "./sweettalk/event"
require "./sweettalk/events"
require "./sweettalk/holding"
require "./sweettalk/entity"
require "./sweettalk/aggregate"
require "./sweettalk/projection"
require "./sweettalk/process"
require "./sweettalk/policy"
require "./sweettalk/schema"
require "./sweettalk/context"
require "./sweettalk/calculation"
require "./sweettalk/kernel"
require "./sweettalk/program"
require "./sweettalk/preview"
require "./sweettalk/action"
require "./sweettalk/requirements"
require "./sweettalk/modules"
require "./sweettalk/report"
