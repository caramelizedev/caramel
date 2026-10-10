# Events: a subject, its facts and its metadata.
module SweetTalk
  # Something that happened to one aggregate: its subject, its facts, recorded as JSON
  # when it was emitted, and its metadata: an id, when it happened and who acted. It
  # travels in a job's params; a notification carries the subject's id. The subject's id
  # is read when the event is dispatched, so a factory's event can name the aggregate it
  # creates.
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

    abstract def __sweettalk_channel : String

    def __sweettalk_subject_id : Int64
      @__sweettalk_subject_id || __sweettalk_subject.__sweettalk_raw_id
    end

    private def __sweettalk_subject : ::SweetTalk::Aggregate
      @__sweettalk_subject || raise ::SweetTalk::Missing.new("#{self.class.name} has no subject")
    end

    def __sweettalk_fields : String
      @__sweettalk_fields
    end

    def __sweettalk_payload : String
      {subject: __sweettalk_subject_id}.to_json
    end

    def __sweettalk_meta : String
      {id: @event_id, at: @occurred_at.to_rfc3339(fraction_digits: 6), by: @actor}.to_json
    end

    private def __sweettalk_stamp : Nil
      @event_id = UUID.random.to_s
      @occurred_at = Time.utc
      @actor = ::Fiber.current.__sweettalk_actor
    end

    private def __sweettalk_restore(meta : String) : Nil
      data = JSON.parse(meta)
      @event_id = data["id"].as_s
      @occurred_at = Time.parse_rfc3339(data["at"].as_s)
      @actor = data["by"].as_s?
    end
  end
end
