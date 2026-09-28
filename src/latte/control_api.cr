require "../caramel/version"

module Caramel::Latte
  # Frappé and Latte talk over a versioned control API (ADR 0016). A request
  # names its version in the path, /v<N>/…. Latte serves every version in
  # VERSIONS and answers any other with `unsupported_api`, its release and
  # this window, so that any Frappé can name the release it needs.
  module ControlAPI
    VERSIONS = [1]
  end
end
