require "../config/application"

command = ARGV.shift? || "help"
if command == "routes"
  width = App::AppRouter.routes.max_of(&.path.size)
  App::AppRouter.routes.each do |entry|
    puts "#{entry.method.ljust(7)} #{entry.path.ljust(width)}  #{entry.action}#{entry.contract.empty? ? "" : "  " + entry.contract}"
  end
  exit
end
unless %w(serve migrate seed).includes?(command)
  puts "Usage: @@SHARD@@ serve|migrate|seed|routes"
  exit(command == "help" ? 0 : 2)
end

database_url = App.database_url(migration: command == "migrate")
if expected = ENV["CARAMEL_EXPECTED_DATABASE_URL"]?
  abort("Database connection differs from the verified launcher configuration") unless database_url == expected
elsif ENV["CARAMEL_ENV"]? == "test"
  abort("Run specs through frappe test")
end
db = Caramel::Database.open(database_url)
begin
  Caramel::Model.database = db
  migrator = Caramel::Migrator.new(db, App::MIGRATIONS)
  case command
  when "migrate"
    puts "Applied #{migrator.migrate} migrations."
  when "seed"
    abort("Pending migrations. Run frappe migrate first.") unless migrator.pending.empty?
    App.seed(db)
  when "serve"
    abort("Pending migrations. Run frappe migrate first.") unless migrator.pending.empty?
    origin = ENV["APP_ORIGIN"]? || abort("APP_ORIGIN is required")
    secret = ENV["APP_SECRET"]? || abort("APP_SECRET is required")
    socket_path = ENV["CARAMEL_SOCKET"]? || abort("CARAMEL_SOCKET is required; use frappe dev")
    parent = File.info?(File.dirname(socket_path), follow_symlinks: false)
    unless parent && parent.directory? && !parent.symlink? && parent.owner_id == LibC.getuid.to_s && (parent.permissions.value & 0o077) == 0
      abort("CARAMEL_SOCKET must be in a private owned directory")
    end
    abort("Application socket is already occupied") if File.info?(socket_path, follow_symlinks: false)
    server = HTTP::Server.new([App.build(db, secret, origin)])
    server.bind_unix(socket_path)
    File.chmod(socket_path, 0o600)
    Signal::INT.trap { server.close }
    Signal::TERM.trap { server.close }
    puts "@@TITLE@@ is ready at #{origin}"
    begin
      server.listen
    ensure
      server.close unless server.closed?
      File.delete?(socket_path)
    end
  end
ensure
  db.close
end
