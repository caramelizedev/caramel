<REPRO>/bin/mise.partial: OK
mise trusted <REPRO>/project/caramel-eval.toml
{"args": ["trust", "<REPRO>/project/caramel-eval.toml"], "seconds": 1.215, "exit": 0}
mise by @jdx – installing 5 tools
mise ✓ conda:pkgconf@3.0.7                 881ms
mise ███░░░░░░░░░░░░░ 1/5 · 3.0s
  github:crystal-lang/crystal@1.21.0  downloading              3.0s  0.7/59.3 MB · 286 kB/s
  aqua:caddyserver/caddy@2.11.4       downloading              3.0s  0.6/16.4 MB · 259 kB/s
  conda:postgresql@18.6               downloading 23 packages  3.0s
  conda:openssl@3.6.4                 downloading 2 packages   3.0s
mise ✓ conda:openssl@3.6.4                 5.0s
mise ██████░░░░░░░░░░ 2/5 · 6.0s
  github:crystal-lang/crystal@1.21.0  downloading              6.0s  1.6/59.3 MB · 302 kB/s
  aqua:caddyserver/caddy@2.11.4       downloading              6.0s  1.5/16.4 MB · 281 kB/s
  conda:postgresql@18.6               downloading 23 packages  6.0s
mise ██████░░░░░░░░░░ 2/5 · 9.0s
  github:crystal-lang/crystal@1.21.0  downloading                                    9.0s  3.0/59.3 MB · 358 kB/s
  aqua:caddyserver/caddy@2.11.4       downloading                                    9.0s  2.9/16.4 MB · 351 kB/s
  conda:postgresql@18.6               installing libxml2-16-2.15.4-heb56d2d_0.conda  9.0s
mise ✓ conda:postgresql@18.6               10.2s
mise ██████████░░░░░░ 3/5 · 12.0s
  github:crystal-lang/crystal@1.21.0  downloading  12.0s  7.9/59.3 MB · 693 kB/s
  aqua:caddyserver/caddy@2.11.4       downloading  12.0s  7.7/16.4 MB · 681 kB/s
mise ✓ aqua:caddyserver/caddy@2.11.4       14.3s  caddy_2.11.4_mac_arm64.tar.gz
mise █████████████░░░ 4/5 · 15.0s
  github:crystal-lang/crystal@1.21.0  downloading  15.0s  26.5/59.3 MB · 1.8 MB/s
mise ██████████████░░ 4/5 · 18.0s
  github:crystal-lang/crystal@1.21.0  downloading  18.0s  56.2/59.3 MB · 3.2 MB/s
mise ✓ github:crystal-lang/crystal@1.21.0  20.7s  crystal-1.21.0-1-darwin-universal.tar.gz
mise ████████████████ 5/5 · installed 5 tools in 20.7s
{"args": ["install", "--locked"], "seconds": 20.772, "exit": 0}
Crystal 1.21.0 [57cf7da50] (2026-07-16)

LLVM: 15.0.7
Default target: aarch64-apple-macosx11.0
{"args": ["exec", "--", "crystal", "--version"], "seconds": 2.468, "exit": 0}
Shards 0.20.0 (2025-12-19)
{"args": ["exec", "--", "shards", "--version"], "seconds": 0.538, "exit": 0}
v2.11.4 h1:XKxkMTgNSizEvKG6QHue6cAsFOteU2qA61w2tKkCWi0=
{"args": ["exec", "--", "caddy", "version"], "seconds": 0.747, "exit": 0}
postgres (PostgreSQL) 18.6
{"args": ["exec", "--", "postgres", "--version"], "seconds": 5.512, "exit": 0}
initdb (PostgreSQL) 18.6
{"args": ["exec", "--", "initdb", "--version"], "seconds": 0.777, "exit": 0}
OpenSSL 3.6.4 25 Aug 2026 (Library: OpenSSL 3.6.4 25 Aug 2026)
{"args": ["exec", "--", "openssl", "version"], "seconds": 1.04, "exit": 0}
3.0.7
{"args": ["exec", "--", "pkg-config", "--version"], "seconds": 0.455, "exit": 0}
{"args": ["exec", "--", "env", "PKG_CONFIG_LIBDIR=<REPRO>/data/installs/conda-openssl/3.6.4/lib/pkgconfig", "CRYSTAL_CACHE_DIR=<REPRO>/crystal-cache", "crystal", "build", "smoke.cr", "-o", "<REPRO>/project/smoke", "--link-flags=-Wl,-rpath,<REPRO>/data/installs/conda-openssl/3.6.4/lib"], "seconds": 1.469, "exit": 0}
{"message":"Caramel","regex":"0"}
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "initdb", "-D", "<REPRO>/cluster", "-U", "caramel_spike", "--locale=C", "--encoding=UTF8", "-A", "trust"]
The files belonging to this database system will be owned by user "<LOCAL_USER>".
This user must also own the server process.

The database cluster will be initialized with locale "C".
The default text search configuration will be set to "english".

Data page checksums are enabled.

creating directory <REPRO>/cluster ... ok
creating subdirectories ... ok
selecting dynamic shared memory implementation ... posix
selecting default "max_connections" ... 100
selecting default "shared_buffers" ... 128MB
selecting default time zone ... America/New_York
creating configuration files ... ok
running bootstrap script ... ok
performing post-bootstrap initialization ... ok
syncing data to disk ... ok

Success. You can now start the database server using:

    <REPRO>/data/installs/conda-postgresql/18.6/bin/pg_ctl -D <REPRO>/cluster -l logfile start

{"args": ["exec", "--", "initdb", "-D", "<REPRO>/cluster", "-U", "caramel_spike", "--locale=C", "--encoding=UTF8", "-A", "trust"], "seconds": 1.045, "exit": 0}
EXIT 0
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-l", "<REPRO>/logs/postgres-server.txt", "-o", "-k <REPRO>/socket -c listen_addresses='' -p 55439 -c unix_socket_permissions=0700", "-w", "start"]
waiting for server to start.... done
server started
{"args": ["exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-l", "<REPRO>/logs/postgres-server.txt", "-o", "-k <REPRO>/socket -c listen_addresses='' -p 55439 -c unix_socket_permissions=0700", "-w", "start"], "seconds": 0.597, "exit": 0}
EXIT 0
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "psql", "-h", "<REPRO>/socket", "-p", "55439", "-U", "caramel_spike", "-d", "postgres", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", "SHOW data_directory; SHOW server_version; SHOW listen_addresses; CREATE TABLE caramel_probe(id integer primary key, title text not null); INSERT INTO caramel_probe VALUES(1, 'Bookshelf'); SELECT title FROM caramel_probe;"]
<REPRO>/cluster
18.6

CREATE TABLE
INSERT 0 1
Bookshelf
{"args": ["exec", "--", "psql", "-h", "<REPRO>/socket", "-p", "55439", "-U", "caramel_spike", "-d", "postgres", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", "SHOW data_directory; SHOW server_version; SHOW listen_addresses; CREATE TABLE caramel_probe(id integer primary key, title text not null); INSERT INTO caramel_probe VALUES(1, 'Bookshelf'); SELECT title FROM caramel_probe;"], "seconds": 1.189, "exit": 0}
EXIT 0
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-m", "fast", "-w", "stop"]
waiting for server to shut down.... done
server stopped
{"args": ["exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-m", "fast", "-w", "stop"], "seconds": 0.13, "exit": 0}
EXIT 0
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-l", "<REPRO>/logs/postgres-server.txt", "-o", "-k <REPRO>/socket -c listen_addresses='' -p 55439 -c unix_socket_permissions=0700", "-w", "start"]
waiting for server to start.... done
server started
{"args": ["exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-l", "<REPRO>/logs/postgres-server.txt", "-o", "-k <REPRO>/socket -c listen_addresses='' -p 55439 -c unix_socket_permissions=0700", "-w", "start"], "seconds": 0.148, "exit": 0}
EXIT 0
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "psql", "-h", "<REPRO>/socket", "-p", "55439", "-U", "caramel_spike", "-d", "postgres", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", "SELECT title FROM caramel_probe WHERE id=1;"]
Bookshelf
{"args": ["exec", "--", "psql", "-h", "<REPRO>/socket", "-p", "55439", "-U", "caramel_spike", "-d", "postgres", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", "SELECT title FROM caramel_probe WHERE id=1;"], "seconds": 0.04, "exit": 0}
EXIT 0
PASS: row survives restart, no TCP listeners configured
COMMAND ["/Library/Developer/CommandLineTools/usr/bin/python3", "<REPRO>/run-mise.py", "exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-m", "fast", "-w", "stop"]
waiting for server to shut down.... done
server stopped
{"args": ["exec", "--", "pg_ctl", "-D", "<REPRO>/cluster", "-m", "fast", "-w", "stop"], "seconds": 0.128, "exit": 0}
EXIT 0
