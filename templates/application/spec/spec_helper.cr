require "spec"
require "../config/application"

# The launcher supplies the verified, separate spec database. Never fall back
# to DATABASE_URL when a test is run outside Frappé.
unless ENV["CARAMEL_ENV"]? == "test" && ENV["CARAMEL_SPEC_DATABASE"]?
  abort("Run these specs with frappe test")
end
unless App.database_url == ENV["CARAMEL_EXPECTED_DATABASE_URL"]?
  abort("Spec connection differs from the verified launcher configuration")
end
SPEC_CONFIG = Caramel::Database::Config.parse(App.database_url)
unless SPEC_CONFIG.database == ENV["CARAMEL_SPEC_DATABASE"] && SPEC_CONFIG.database.matches?(/\Acaramel_spec_[0-9a-f]{16}\z/)
  abort("Spec database identity differs; development data was not touched")
end
SPEC_DB = Caramel::Database.open(App.database_url)
unless SPEC_DB.query_one("SELECT current_database()", as: String) == ENV["CARAMEL_SPEC_DATABASE"]
  SPEC_DB.close
  abort("Connected spec database identity differs")
end
Spec.after_suite { SPEC_DB.close }
