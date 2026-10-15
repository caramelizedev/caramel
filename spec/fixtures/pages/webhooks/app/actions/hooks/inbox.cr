require "openssl/hmac"
require "crypto/subtle"

module App::Hooks
  # A signed webhook: the exact bytes, no browser CSRF, an HMAC over the body.
  struct Inbox < App::ApplicationAction
    ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?

    contract do
    end

    def handle(contract : Contract)
      event = JSON.parse(String.new(raw_body))
      Log.info { "Webhook #{event["id"]?} #{event["type"]?}" }
      Caramel::Response.new(202)
    end

    # Hex HMAC-SHA256 of the body, sent in one header. A provider that signs
    # a timestamp with the body changes only this method.
    private def signed? : Bool
      signature = request.headers["X-Signature"]? || return false
      expected = OpenSSL::HMAC.hexdigest(:sha256, ENV["WEBHOOK_SECRET"], raw_body)
      Crypto::Subtle.constant_time_compare(signature, expected)
    end
  end
end
