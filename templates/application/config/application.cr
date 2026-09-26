require "caramel"
require "yaml"

module App
  MIGRATIONS = [] of Caramel::Migration
  DATABASE_SETTINGS = YAML.parse({{ read_file("#{__DIR__}/database.yml") }})
  TITLE = "@@TITLE@@"

  def self.database_url(migration = false) : String
    environment = ENV["CARAMEL_ENV"]? || "production"
    raise "CARAMEL_ENV must be development, test or production" unless %w(development test production).includes?(environment)
    key = DATABASE_SETTINGS[environment][migration ? "migration_url_env" : "url_env"].as_s
    ENV[key]? || raise "Missing database configuration: #{key}"
  end
end

require "../app/models/*"
require "./paths"
require "../app/actions/application_action"
require "../app/actions/*"
require "../app/actions/**"
require "../db/migrations/*"
require "../db/seeds"
require "./routes"

module App
  def self.build(db : DB::Database, secret : String, origin : String) : Caramel::Application
    Caramel::Model.database = db
    Caramel::Application.new(App::AppRouter.new, Caramel::CSRF.new(secret, origin), "#{__DIR__}/../public")
  end
end
