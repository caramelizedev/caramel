# PostgreSQL driver audit

The runtime pins `will/crystal-pg` at **v0.30.0** (commit
`98884c0c14c28f4c0466fd188f0c4d713e1482fb`) and `crystal-lang/crystal-db` at
**v0.14.0** (commit `173e395e7a5b83b5696c849c3a4fa1e1da466ce2`). These are the
release tags used by the local shard lock. `pg` declares `db ~> 0.14.0` in its
[shard manifest](https://github.com/will/crystal-pg/blob/v0.30.0/shard.yml#L1-L8);
both shards support Crystal 1.x through `< 2.0`.

## TLS behavior

The normal `PQ::Connection` constructor opens a TCP or Unix socket and invokes
`negotiate_ssl` for TCP unless `sslmode=disable`
([connection.cr:24-40](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/connection.cr#L24-L40)).
That negotiation sends PostgreSQL's 8-byte SSLRequest, but the driver creates a
client context with `VerifyMode::NONE`
([connection.cr:45-63](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/connection.cr#L45-L63)).
Consequently `sslrootcert` loads a CA file without enabling peer verification,
and `verify-ca`/`verify-full` do not verify the peer. A server response of `N`
also falls back to plaintext for those modes; only `sslmode=require` rejects
that response ([connection.cr:65-85](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/connection.cr#L65-L85)).
This is the security gap that prevents the stock URI constructor from satisfying
Caramel's production `verify-full` requirement.

Caramel uses the driver's supported wrapped-socket overload
([connection.cr:42-43](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/connection.cr#L42-L43)):

1. Open TCP with five-second DNS/connect arguments and five-second
   read/write inactivity limits.
2. Send the SSLRequest and require exactly `S`; `N`, EOF, or any other byte is
   rejected before PostgreSQL startup can proceed.
3. Build Crystal 1.21's `OpenSSL::SSL::Context::Client` with
   `VerifyMode::PEER`, optional explicit CA/client certificate/key, and the
   configured hostname. Crystal's `hostname:` option drives SNI and hostname
   verification when peer verification is enabled.
4. Pass the verified TLS socket to `PQ::Connection.new(socket, conninfo)` and
   let `PG::Connection.new(options, pq)` perform the normal PostgreSQL startup
   ([pg connection.cr:16-23](https://github.com/will/crystal-pg/blob/v0.30.0/src/pg/connection.cr#L16-L23)).

These are practical per-operation limits rather than a hard startup deadline.
Crystal's DNS timeout argument is currently honored only on Windows, TCP
connect timeout is applied per resolved address, and `UNIXSocket.new` has no
connect-timeout argument. A global startup deadline and non-blocking DNS path
remain a production/Latte gate before claiming a hard startup bound; this
wrapper does not implement that broader mechanism.

Unix socket URLs use an absolute `host` query value and connect to
`.s.PGSQL.<port>` in that directory. TLS is disabled for this transport, and
Caramel accepts the directory only when it exists, belongs to the current user,
and has no group/world permissions. The upstream `ConnInfo` treats an absolute
host as a Unix socket and otherwise falls back to environment values
([conninfo.cr:127-146](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/conninfo.cr#L127-L146));
Caramel supplies every identity, database, password, host, and port explicitly
to avoid those fallbacks and passes an explicit empty password for local trust.

## URI and pool surface

Upstream accepts `host`, `port`, `sslmode`, `sslcert`, `sslkey`, and
`sslrootcert` query values ([conninfo.cr:78-124](https://github.com/will/crystal-pg/blob/v0.30.0/src/pq/conninfo.cr#L78-L124)).
Caramel accepts that narrow set, requires `sslmode=verify-full` for TCP (the
default when omitted), rejects conflicting authority/query host or port values,
and rejects URL fragments and unsupported/repeated options.

`DB::Pool::Options` defaults to one initial connection, unlimited maximum size,
one idle connection, a five-second checkout timeout, and one retry
([pool.cr:7-29](https://github.com/crystal-lang/crystal-db/blob/v0.14.0/src/db/pool.cr#L7-L29)).
Caramel bounds the caller's maximum at 1..32, opens one initial connection and
creates further connections on demand,
uses the requested value as both maximum and idle bound, and sets
`retry_attempts: 0` so a failed mutation is not replayed ambiguously. The
Caramel runtime runs `SET TIME ZONE 'UTC'` inside its connection factory before a
resource is returned to the pool. This keeps setup failures in the same cleanup
scope as the PG object and transport for both initial and lazy connections;
the upstream `setup_connection` hook runs future setup inside the pool factory
without owning failure cleanup ([database.cr:42-79](https://github.com/crystal-lang/crystal-db/blob/v0.14.0/src/db/database.cr#L42-L79)).

Queries remain parameterized through crystal-db's normal API. PostgreSQL uses
`$1`, `$2`, and so on; crystal-db does not rewrite placeholders
([README.md:43-61](https://github.com/crystal-lang/crystal-db/blob/v0.14.0/README.md#L43-L61)).
The pg statement path encodes arguments and sends Parse/Bind/Describe/Execute
messages ([statement.cr:10-18](https://github.com/will/crystal-pg/blob/v0.30.0/src/pg/statement.cr#L10-L18)).
Use `db.exec("UPDATE ... WHERE id = $1", id)` or
`db.query_one("SELECT ... WHERE id = $1", id, as: Type)` rather than string
interpolation.
