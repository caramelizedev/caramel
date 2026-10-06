require "digest/sha256"
require "./event"
require "./frames"
require "./redact"

module Caramel::Crema
  # An exception reduced to what may be kept: its class, a redacted message
  # and backtrace, and a fingerprint that groups repeats of one defect.
  struct ErrorReport
    MAX_MESSAGE   = 8192
    MAX_FRAME     = 2048
    MAX_BACKTRACE =   50
    MAX_CAUSES    =    5

    getter error_class : String
    getter message : String
    getter backtrace : Array(String)
    getter fingerprint : String
    getter location : String?
    getter? handled : Bool
    getter source : String?
    getter request_id : String?
    getter trace_id : String?
    getter occurred_at : Time
    getter causes : Array(String)

    def initialize(@error_class : String,
                   @message : String,
                   @backtrace : Array(String),
                   @fingerprint : String,
                   @location : String?,
                   @handled : Bool,
                   @source : String?,
                   @request_id : String?,
                   @trace_id : String?,
                   @occurred_at : Time,
                   @causes : Array(String))
    end

    def self.build(error : Exception,
                   handled : Bool,
                   source : String?,
                   request_id : String? = nil,
                   trace_id : String? = nil) : ErrorReport
      secrets = Crema.secrets
      root = Frames.root
      frames = error.backtrace? || [] of String
      frame = Frames.first_application(frames, root) || first_frame(frames)
      new(error.class.to_s,
        Redact.text(error.message || "", secrets, MAX_MESSAGE),
        frames.first(MAX_BACKTRACE).map { |text| Redact.text(text, secrets, MAX_FRAME) },
        fingerprint_of(error.class.to_s, frame),
        frame.try { |found| location_of(found, root) },
        handled, source, request_id, trace_id, Time.utc, causes_of(error))
    end

    # What `build` falls back to when redaction or frame parsing itself fails: the
    # class, a fingerprint from the class alone, and no message or backtrace.
    def self.minimal(error : Exception,
                     handled : Bool,
                     source : String?,
                     request_id : String? = nil,
                     trace_id : String? = nil) : ErrorReport
      error_class = error.class.to_s
      new(error_class, "[unavailable]", [] of String, fingerprint_of(error_class, nil),
        nil, handled, source, request_id, trace_id, Time.utc, [] of String)
    end

    # The first 12 hex characters of a digest of the class and the fingerprint
    # frame's file and method. Lines, columns and messages never enter it.
    def self.fingerprint_of(error_class : String, frame : Frame?) : String
      path = frame.try(&.path) || ""
      label = frame.try(&.label) || ""
      Digest::SHA256.hexdigest("#{error_class}\n#{path}\n#{label}")[0, 12]
    end

    def self.first_frame(frames : Array(String)) : Frame?
      frames.each do |text|
        frame = Frames.parse(text)
        return frame if frame
      end
      nil
    end

    private def self.location_of(frame : Frame, root : String) : String
      location = "#{Frames.relative(frame.path, root)}:#{frame.line}"
      frame.column.try { |column| location += ":#{column}" }
      location
    end

    private def self.causes_of(error : Exception) : Array(String)
      causes = [] of String
      cause = error.cause
      while cause && causes.size < MAX_CAUSES
        causes << cause.class.to_s
        cause = cause.cause
      end
      causes
    end

    def to_event(detail : Detail) : ErrorEvent
      event = ErrorEvent.new(@error_class, @fingerprint, @handled,
        @occurred_at.to_rfc3339(fraction_digits: 3))
      event.location = @location
      event.source = @source
      event.request_id = @request_id
      event.trace_id = @trace_id
      event.causes = @causes
      return event unless detail.development?

      event.message = @message
      event.backtrace = @backtrace
      event
    end
  end
end
