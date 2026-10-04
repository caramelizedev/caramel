require "json"

module Caramel::Crema
  # How much a rendered event may say. Production events carry no request
  # path, bind values, source locations, messages or backtraces.
  enum Detail
    Production
    Development
  end

  # Wire format, version 1: one JSON object per line, shared by the
  # application, Frappé, the ops socket and Latte. Nil fields are omitted.
  WIRE_VERSION = 1

  class RepeatEvent
    include JSON::Serializable

    property sql : String
    property count : Int32
    property source : String?

    def initialize(@sql : String, @count : Int32, @source : String? = nil)
    end
  end

  class SpanEvent
    include JSON::Serializable

    property kind : String
    property name : String
    property detail : String?
    property offset_ms : Float64
    property duration_ms : Float64
    property rows : Int64?
    property status : Int32?
    property level : String?
    property error_class : String?
    property source : String?
    property binds : Array(String)?

    def initialize(@kind : String,
                   @name : String,
                   @offset_ms : Float64,
                   @duration_ms : Float64)
    end
  end

  class ErrorEvent
    include JSON::Serializable

    getter v : Int32 = WIRE_VERSION
    getter type : String = "error"
    property error_class : String
    property fingerprint : String
    property location : String?
    property? handled : Bool
    property source : String?
    property request_id : String?
    property trace_id : String?
    property at : String
    property causes : Array(String) = [] of String
    property message : String?
    property backtrace : Array(String)?

    def initialize(@error_class : String,
                   @fingerprint : String,
                   @handled : Bool,
                   @at : String)
    end
  end

  class TraceEvent
    include JSON::Serializable

    getter v : Int32 = WIRE_VERSION
    getter type : String = "trace"
    property kind : String
    property name : String
    property trace_id : String
    property span_id : String
    property parent_id : String?
    property request_id : String?
    property started_at : String
    property duration_ms : Float64
    property outcome : String
    property status : Int32?
    property method : String?
    property route : String?
    property action : String?
    property path : String?
    property job_id : Int64?
    property queue : String?
    property attempt : Int32?
    property queue_lag_ms : Float64?
    property? debug : Bool = false
    property? streamed : Bool = false
    property? slow : Bool = false
    property bytes : Int64?
    property db_count : Int32 = 0
    property db_ms : Float64 = 0.0
    property db_wait_ms : Float64 = 0.0
    property view_ms : Float64 = 0.0
    property outbound_count : Int32 = 0
    property outbound_ms : Float64 = 0.0
    property cache_hits : Int32 = 0
    property cache_misses : Int32 = 0
    property enqueued : Int32 = 0
    property slow_queries : Int32 = 0
    property dropped_spans : Int32 = 0
    property repeated : Array(RepeatEvent) = [] of RepeatEvent
    property spans : Array(SpanEvent) = [] of SpanEvent
    property error : ErrorEvent?
    # Why a ring kept the trace: `error`, `slow` or `debug`.
    property reason : String?

    def initialize(@kind : String,
                   @name : String,
                   @trace_id : String,
                   @span_id : String,
                   @started_at : String,
                   @duration_ms : Float64,
                   @outcome : String)
    end
  end

  class BuildDiagnostic
    include JSON::Serializable

    property code : String
    property file : String
    property line : Int32
    property column : Int32
    property message : String
    property remediation : String?

    def initialize(@code : String,
                   @file : String,
                   @line : Int32,
                   @column : Int32,
                   @message : String,
                   @remediation : String? = nil)
    end
  end

  # A Frappé build or type-check result. Only Frappé writes these.
  class BuildEvent
    include JSON::Serializable

    getter v : Int32 = WIRE_VERSION
    getter type : String = "build"
    property at : String
    property state : String
    property duration_ms : Float64
    property diagnostics : Array(BuildDiagnostic) = [] of BuildDiagnostic
    property message : String?

    def initialize(@at : String, @state : String, @duration_ms : Float64)
    end
  end
end
