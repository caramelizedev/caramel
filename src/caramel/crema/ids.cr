require "random/secure"
require "uuid"

module Caramel::Crema
  # Request, trace and span identifiers, and the W3C `traceparent` header.
  module Ids
    REQUEST_ID  = /\A[A-Za-z0-9._:\-]{8,128}\z/
    TRACEPARENT = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/

    # A fresh trace id (32 lowercase hex) and span id (16 hex).
    def self.generate : {String, String}
      hex = Random::Secure.random_bytes(24).hexstring
      {hex[0, 32], hex[32, 16]}
    end

    # The inbound `X-Request-ID` when it is a plain token, else a new UUID.
    def self.request_id(header : String?) : String
      return header if header && header.matches?(REQUEST_ID)

      UUID.random.to_s
    end

    # The trace id, parent id and sampled bit of a valid `traceparent`.
    def self.parse_traceparent(header : String?) : {String, String, Bool}?
      match = header.try { |value| TRACEPARENT.match(value) } || return
      trace_id, parent_id = match[1], match[2]
      return if zero?(trace_id) || zero?(parent_id)

      {trace_id, parent_id, (match[3].to_i(16) & 1) == 1}
    end

    def self.traceparent(trace_id : String, span_id : String, sampled : Bool) : String
      "00-#{trace_id}-#{span_id}-#{sampled ? "01" : "00"}"
    end

    private def self.zero?(id : String) : Bool
      id.each_char.all?(&.==('0'))
    end
  end
end
