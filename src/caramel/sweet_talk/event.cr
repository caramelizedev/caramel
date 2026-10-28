# Events: a subject, its facts and its metadata.
module SweetTalk
  # Something that happened to one aggregate, or in one context: its subject, its facts,
  # recorded as JSON when it was emitted, and its metadata: an id, when it happened, who
  # acted, what caused it and the flow it belongs to. It travels in a job's params; a
  # notification carries the subject's id. The subject's id is read when the event is
  # dispatched, so a factory's event can name the aggregate it creates. A context's event
  # has the bound tenant for its subject in a program that requires caramel/tenancy, and
  # none otherwise.
  abstract class Event
    @__sweettalk_fields : String = ""
    @__sweettalk_subject : ::SweetTalk::Aggregate? = nil
    @__sweettalk_subject_id : Int64? = nil

    # A random UUID, the same in every job that follows this event.
    getter event_id : String = ""

    # When the event was emitted.
    getter occurred_at : Time = Time::UNIX_EPOCH

    # Who acted, as `SweetTalk.acting` named them; nil outside it.
    getter actor : String? = nil

    # The event whose handler emitted this one, or whose step armed the deadline that did;
    # nil for a command outside a handler.
    getter cause_id : String? = nil

    # The same in every event that follows from one command: the trace id it ran in, or a
    # random 32-hex id outside a trace.
    getter flow_id : String = ""

    abstract def __sweettalk_channel : String

    def __sweettalk_subject_id : Int64?
      @__sweettalk_subject_id || @__sweettalk_subject.try(&.__sweettalk_raw_id)
    end

    private def __sweettalk_subject : ::SweetTalk::Aggregate
      @__sweettalk_subject || raise NilAssertionError.new("#{self.class.name} has no subject")
    end

    def __sweettalk_fields : String
      @__sweettalk_fields
    end

    # Records the fields again, once the command has saved, so an entity among them shows
    # the id its row got.
    def __sweettalk_repack : Nil
      @__sweettalk_fields = __sweettalk_record
    end

    def __sweettalk_payload : String
      {subject: __sweettalk_subject_id}.to_json
    end

    def __sweettalk_meta : String
      {id: @event_id, at: @occurred_at.to_rfc3339(fraction_digits: 6), by: @actor,
       cause: @cause_id, flow: @flow_id}.to_json
    end

    private def __sweettalk_stamp : Nil
      @event_id = UUID.random.to_s
      @occurred_at = Time.utc
      fiber = ::Fiber.current
      @actor = fiber.__sweettalk_actor
      @cause_id = fiber.__sweettalk_cause
      @flow_id = ::SweetTalk.__sweettalk_flow
    end

    private def __sweettalk_restore(meta : String) : Nil
      data = JSON.parse(meta)
      @event_id = data["id"].as_s
      @occurred_at = Time.parse_rfc3339(data["at"].as_s)
      @actor = data["by"].as_s?
      @cause_id = data["cause"]?.try(&.as_s?)
      @flow_id = data["flow"]?.try(&.as_s?) || @event_id
    end
  end
end
