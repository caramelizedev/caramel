require "../config/application"

command = ARGV.first? || "help"
unless {"migrate", "serve", "seed"}.includes?(command)
  puts "Usage: bookshelf migrate|serve|seed"
  puts "Set DATABASE_URL; serve also requires APP_SECRET, APP_ORIGIN and CARAMEL_SOCKET."
  exit(command == "help" ? 0 : 2)
end
url = ENV["DATABASE_URL"]? || abort("DATABASE_URL is required")
db = Caramel::Database.open(url)
begin
  migrator = Caramel::Migrator.new(db, Bookshelf::MIGRATIONS)
  case command
  when "migrate"
    puts "Applied #{migrator.migrate} migrations."
  when "seed"
    abort("Run bookshelf migrate first") unless migrator.pending.empty?
    store = Bookshelf::BookStore.new(db)
    if store.all.empty?
      [{"A Wizard of Earthsea", "Ursula K. Le Guin"}, {"The Creative Act", "Rick Rubin"}, {"Piranesi", "Susanna Clarke"}, {"The Art of Noticing", "Rob Walker"}].each do |title, author|
        store.save(Bookshelf::Book.new(title, author))
      end
      puts "Added four books."
    else
      puts "Your shelf already has books; seed left it unchanged."
    end
  when "serve"
    abort("Pending migrations. Run bookshelf migrate before starting.") unless migrator.pending.empty?
    origin = ENV["APP_ORIGIN"]? || abort("APP_ORIGIN is required (for example https://bookshelf.caramel)")
    secret = ENV["APP_SECRET"]? || abort("APP_SECRET is required")
    socket_path = ENV["CARAMEL_SOCKET"]? || abort("CARAMEL_SOCKET is required; serve behind the HTTPS proxy")
    parent = File.info?(File.dirname(socket_path), follow_symlinks: false)
    unless parent && parent.directory? && parent.owner_id == LibC.getuid.to_s && (parent.permissions.value & 0o077) == 0
      abort("CARAMEL_SOCKET must be in a private directory owned by the current user")
    end
    abort("CARAMEL_SOCKET already exists; refusing to replace another process's socket") if File.exists?(socket_path)
    app = Bookshelf::App.new(db, secret, origin)
    server = HTTP::Server.new([app.application])
    server.bind_unix(socket_path)
    File.chmod(socket_path, 0o600)
    Signal::INT.trap { server.close }
    Signal::TERM.trap { server.close }
    puts "Bookshelf is ready for its HTTPS proxy at #{origin}"
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
