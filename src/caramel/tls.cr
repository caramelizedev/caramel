require "openssl"
require "uri"

module Caramel
  # The TLS client contexts Caramel opens itself. Crystal before 1.22.1 gives every
  # `OpenSSL::SSL::Context` OpenSSL 1.0's `SSL_OP_ALL` bits, which OpenSSL 3 reads as
  # other options: no extended master secret, legacy renegotiation with servers and no
  # `close_notify` check (GHSA-7jw4-6xx8-g2r9). A context made here clears them. The
  # managed toolchain and release image pin 1.22.1, but Shards only warns when an
  # application builds with an older compiler, so the framework clears them itself.
  module TLS
    LEGACY_OPTIONS = OpenSSL::SSL::Options.new(0x18d)

    def self.client_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      context.remove_options(LEGACY_OPTIONS)
      context
    end

    # The context an `HTTP::Client` needs for *uri*: none for http, which
    # `HTTP::Client` rejects together with a context.
    def self.client_context(uri : URI) : OpenSSL::SSL::Context::Client?
      client_context if uri.scheme == "https"
    end
  end
end
