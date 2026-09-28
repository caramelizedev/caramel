require "spec"
require "caramel/corretto"
require "../config/application"

# `frappe corretto` runs each worker against its own Latte clone of the
# migrated spec database; Corretto refuses any other database, wraps every
# example in a rolled-back savepoint and answers outbound HTTP from wire stubs.
Corretto.configure(App)
