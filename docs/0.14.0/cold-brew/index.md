Reference / Cold Brew

# Work that outlives the request.

Define typed jobs, run workers and schedules, publish notifications, and cache strings in your application’s PostgreSQL database.

## Define a job {#c-coldbrew-define}

A job is a struct that extends `Caramel::ColdBrew::Job` and implements `perform`. Each `param` declares a typed field and its getter. The params form the JSON payload stored with the job. A default value makes the param optional when enqueueing.

**app/jobs/send_invitation.cr**

```crystal
struct SendInvitation < Caramel::ColdBrew::Job
  queue "mailers"
  retry_on IO::TimeoutError, attempts: 5, backoff: :exponential, base: 2.seconds
  param invite_id : Int64
  param note : String = ""

  def perform
    # Load the invite by invite_id and send it.
  end
end
```

`queue` takes a literal name of 1 to 63 characters from `a-z`, digits, `_`, `.`, `:` and `-`. A job without one uses `default`. Declaring the queue twice, declaring a param twice, or naming a param `run_at` or `priority` fails compilation. Param types must round-trip through JSON. Keep payloads small: store an id and load the record in `perform`.

## Retry failures {#c-coldbrew-retry}

When `perform` raises, its transaction rolls back and Cold Brew chooses a retry rule. `retry_on` takes an exception class, `attempts`, `backoff` and `base`. `attempts` counts every run, the first included. After the last run, the job is failed.

- `:exponential` waits `base * 2**(attempt - 1)`.
- `:linear` waits `base * attempt`.

Rules on the job come first, then rules on its abstract parents, then global rules. The first matching rule wins. With no match, a job runs 3 times with exponential backoff from 1 second. A job whose class name no compiled job claims fails at once, without retries.

**Application boot · a rule for every job**

```crystal
Caramel::ColdBrew::Job.retry_on Socket::ConnectError,
  attempts: 6, backoff: :linear, base: 3.seconds
```

A failed row keeps the error’s class, message and first backtrace lines in `last_error`, up to 4,000 characters. Status and hooks expose only the class.

[Read status and observe failures →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

## Enqueue a job {#c-coldbrew-enqueue}

`enqueue` takes one keyword per param, plus `run_at` and `priority`. It returns the job’s `Int64` id. An unknown keyword or a mistyped value fails compilation at the call.

**Inside an action or another job**

```crystal
SugarORM::Repo.transaction do
  invite = Invite.create!(email: "elena@acme.com")
  SendInvitation.enqueue(invite_id: invite.id)
end

id = SendInvitation.enqueue(invite_id: 42, run_at: 10.minutes.from_now, priority: 5)
SendInvitation.enqueue(db, invite_id: 42, note: "resend")
```

The row is written through `SugarORM::Repo`’s current connection. Inside `SugarORM::Repo.transaction`, the job commits or rolls back with the business write. `run_at` defaults to now, and a job runs once it is due. Higher `priority` runs first; the default is 0, and equal priorities run in id order. The overload that takes a `SugarORM::Handle` first writes on that handle, such as a spec’s `db`.

## Rename a job without losing queued work {#c-coldbrew-rename}

A row stores the job’s fully qualified class name, and a worker runs the compiled job of that name. `enqueue` always stores the current name, so after you rename or move a class, rows queued before the deploy still carry the old one. List the old names on the class that replaced it, and a row queued under any of them runs that class with its stored params and its retry rules.

**app/jobs/restock_tea.cr**

```crystal
struct App::RestockTea < Caramel::ColdBrew::Job
  renamed_from "App::Restock", "App::Stock::Restock"
  param tea_id : Int64

  def perform
    # Runs rows queued as App::Restock or App::Stock::Restock, too.
  end
end
```

`renamed_from` takes string literals of fully qualified class names, once per concrete job; on an abstract parent it fails compilation. Naming the job’s own class, or a name that is another job’s class or alias, fails compilation. Keep an old name until no row carries it.

`Caramel::ColdBrew.unknown_queued_class_names(db)` returns the sorted class names of waiting rows, neither locked, finished nor failed, that this binary compiles neither as a job nor as an alias. It is empty when every queued job can run. `work` and `migrate` log a warning naming them and carry on, so run the new binary’s `migrate` before the old one stops, and read the list from a deploy script that should fail on it.

**Application boot or a deploy script**

```crystal
names = Caramel::ColdBrew.unknown_queued_class_names(db)
abort "Stranded jobs: #{names.join(", ")}" unless names.empty?
```

## Run workers {#c-coldbrew-run}

The application binary’s `serve` command starts Cold Brew beside the HTTP server. Its `work` command starts the same workers, maintenance and schedules without HTTP. Both read queue settings from the environment, and `work`’s flags replace them.

- `CARAMEL_WORKER_QUEUES`: Comma-separated queue names, each once; defaults to default
- `CARAMEL_WORKER_CONCURRENCY`: Fibers per queue; defaults to 4
- `--queues=NAMES`: work only: replaces CARAMEL_WORKER_QUEUES
- `--concurrency=N`: work only: replaces CARAMEL_WORKER_CONCURRENCY
- `--no-scheduler`: work only: leaves every schedule to another process

**Terminal · compiled application**

```bash
./bin/bookshelf work --queues=default,mailers --concurrency=4
./bin/bookshelf work --queues=default --no-scheduler
```

Workers use a connection pool of their own, so jobs never wait for request connections. The pool holds one connection per fiber plus one, up to 32. Concurrency is therefore limited to 31 divided by the number of queues. Invalid settings stop the process before it connects.

On SIGTERM or SIGINT, workers stop claiming jobs, and in-flight jobs and schedule blocks finish before the process exits. `work` refuses pending migrations and `CARAMEL_ENV=test`. Under test, `serve` starts no workers.

Maintenance runs every 60 seconds in every process, even with `--no-scheduler`. It releases locks older than 15 minutes whose database session has ended, so those jobs run again. It deletes expired cache entries and creates daily job partitions from today through seven days ahead, in UTC. It drops partitions that ended more than 7 days ago and hold only finished or failed jobs; `status` then returns nil for those jobs.

## Schedule recurring work {#c-coldbrew-every}

`Caramel::ColdBrew.every(span, name)` declares a block that runs once per period. Declare schedules at boot, before `serve` or `work` starts.

**Application boot**

```crystal
Caramel::ColdBrew.every(1.hour, "nightly-cleanup") { CleanupJob.enqueue }
```

Every process ticks each schedule, but a database lease lets one process run the block per period. The block runs inside the lease’s transaction, so its writes commit with the lease. The span must be at least 1 second, and the name must be present and unique; otherwise `every` raises `ArgumentError`. A raising block is logged and tried again after its span or one minute, whichever is shorter.

## Publish and subscribe {#c-coldbrew-pubsub}

`publish(channel, payload)` sends a string with PostgreSQL `pg_notify` on the current Repo connection. Inside a transaction, the notification is delivered only when the transaction commits.

**Inside a job’s perform method**

```crystal
SugarORM::Repo.transaction do
  Caramel::ColdBrew.publish("board_#{board_id}", board_id.to_s)
end
```

Channel names use the queue-name rules: 1 to 63 characters from `a-z`, digits, `_`, `.`, `:` and `-`. Payloads hold at most 8,000 bytes, so publish an id and read the record instead. Breaking either limit raises `ArgumentError`.

`subscribe` has two forms. The block form creates a `Channel(String)` and unsubscribes when the block ends. `subscribe(channel, subscriber)` delivers into your channel until `unsubscribe`, a closed channel, or the end of the fiber that subscribed. A streaming action’s subscription therefore ends with its stream.

**Inside an action’s handle method**

```crystal
stream "text/event-stream" do |io|
  Caramel::ColdBrew.subscribe("board_#{id}") do |updates|
    loop { Caramel::SSE.write(io, event: "BoardUpdated", data: updates.receive) }
  end
end
```

Subscribing needs the process’s broker, which `serve` and `work` start. Elsewhere, set `Caramel::ColdBrew.broker = Caramel::ColdBrew::Broker.new(database_url)` first. Delivery is at most once. Each subscriber receives payloads in publish order. A payload it does not receive within 1 second is dropped, as are payloads beyond 10,000 waiting and notifications sent while the broker reconnects.

## Cache strings {#c-coldbrew-cache}

`Caramel::Cache` stores string values in the unlogged `caramel_cache` table, through the current Repo connection.

**Inside an action**

```crystal
report = Caramel::Cache.fetch("report:2026-10", expires_in: 10.minutes) do
  "computed report"
end
Caramel::Cache.write("banner", "Maintenance at noon")
Caramel::Cache.read("banner")   # => "Maintenance at noon"
Caramel::Cache.delete("banner") # => true
```

- `write(key, value, expires_in)`: Inserts or replaces; nil expires_in keeps the entry
- `read(key)`: The value, or nil when missing or expired
- `fetch(key, expires_in) { … }`: The cached value, else the block’s value, written
- `delete(key)`: True when an entry was removed
- `clear`: Deletes every entry
- `vacuum`: Deletes expired entries and returns the count

A zero or negative `expires_in` raises `ArgumentError`. Maintenance vacuums expired entries every minute. Keep only values you can compute again.

## Drain queues in specs {#c-coldbrew-test}

Specs run no workers. `Caramel::ColdBrew.drain_queue!(db, queue)` runs the queue’s due jobs synchronously on `db`, including jobs that those jobs enqueue. It returns the number of runs.

**Inside a Corretto session · after enqueueing**

```crystal
Caramel::ColdBrew.drain_queue!(db, "mailers")
Caramel::ColdBrew.status(db, id).not_nil!.state
  .should eq(Caramel::ColdBrew::JobState::Finished)
```

On a spec’s transaction, each job runs in a savepoint. A failed job follows its retry rule and does not run again in the same drain. `drain_queue!` then raises `DrainFailure`, listing every failed run; `drain_queue` does not raise. Pass `include_scheduled: true` to run jobs that are not yet due. A drain that has run 1,000 jobs while more are still due raises `DrainLimitExceeded`.

[Test requests with Corretto →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Test it →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/cold-brew/
