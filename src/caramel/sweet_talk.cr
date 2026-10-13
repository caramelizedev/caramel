# SweetTalk, an opt-in language for Domain-Driven Design (ADRs 0030 and 0031).
#
# Each word is a macro. An aggregate expands into a SugarORM schema and changeset plus a
# domain class over them; a command runs in `Repo.transaction` on one aggregate; an event
# records its facts and becomes Cold Brew jobs, enqueued in that transaction, for the
# policies, projections and processes that follow it, and a PubSub notification for live
# pages. Whole-program checks are `{% %}` inside method bodies, which expand once the top
# level is complete.
require "../caramel"
require "uuid"
require "./sweet_talk/errors"
require "./sweet_talk/facts"
require "./sweet_talk/boundary"
require "./sweet_talk/value"
require "./sweet_talk/model"
require "./sweet_talk/event"
require "./sweet_talk/entity"
require "./sweet_talk/aggregate"
require "./sweet_talk/projection"
require "./sweet_talk/process"
require "./sweet_talk/policy"
require "./sweet_talk/schema"
require "./sweet_talk/context"
require "./sweet_talk/program"
require "./sweet_talk/action"
