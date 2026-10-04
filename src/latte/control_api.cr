require "../caramel/version"

module Caramel::Latte
  # Frappé and Latte talk over a versioned control API (ADR 0016). A request
  # names its version in the path, /v<N>/…. Latte serves every version in
  # VERSIONS and answers any other with `unsupported_api`, its release and
  # this window, so that any Frappé can name the release it needs. Version 2
  # adds each site's development error count and newest error (ADR 0029);
  # version 1 answers as it always has.
  module ControlAPI
    VERSIONS = [1, 2]
  end
end
