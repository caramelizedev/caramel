require "caramel"

module App
  TITLE      = "@@TITLE@@"
  MIGRATIONS = Caramel::ColdBrew::MIGRATIONS.dup
end

require "../app/models/*"
require "../app/changesets/*"
require "../app/jobs/*"
require "./paths"
require "../app/actions/application_action"
require "../app/actions/*"
require "../app/actions/**"
require "../db/migrations/*"
require "../db/seeds"
require "./routes"
