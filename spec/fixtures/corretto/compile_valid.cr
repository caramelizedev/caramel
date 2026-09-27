require "spec"
require "../../../src/caramel/corretto"

# A double defined inside the application is not a mocking library.
module Billing
  struct Double
  end
end
