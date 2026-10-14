Reference / Cold Brew

# Work that outlives the request.

Define typed jobs, run workers and schedules, publish notifications, and cache strings in your application’s PostgreSQL database.

| Contract | Value |
| --- | --- |
| Release | 0.14.0 |
| Needs | A Caramel application and its PostgreSQL database |
| Covers | Jobs, retries, renames, workers, schedules, PubSub, cache |
| Proved by | `drain_queue!` in a Corretto spec |

Learning it for the first time? The recipe [Run a background job](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md) walks through it in order. This page lists every name and limit.

## Limits at a glance {#c-coldbrew-limits}

| Limit | Value |
| --- | --- |
| Queue and channel names: `a-z`, digits, `_ . : -` | 1–63 characters |
| Default retry: exponential backoff from 1 second | 3 runs |
| Default worker fibers per queue | 4 |
| Worker fibers across all queues, at most | 31 |
| Worker connections: one per fiber, plus one | 32 |
| Maintenance runs in every process | 60 s |
| A lock is released once its session has ended | 15 min |
| Job partitions: created through that many days ahead, dropped once ended more than that many days ago | 7 days |
| Shortest schedule span | 1 s |
| Longest wait before a raising schedule block runs again | 1 minute |
| PubSub payload; publish an id instead | 8,000 bytes |
| Payload not received within this time is dropped | 1 s |
| Payloads waiting per subscriber before dropping | 10,000 |
| A failed job’s `last_error` | 4,000 characters |
| One drain in a spec, then it raises | 1,000 jobs |

## A job is a struct with typed params {#c-coldbrew-define}

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

| Condition | Outcome |
| --- | --- |
| A job without `queue` | uses `default` |
| A `queue` that is not a literal name of 1 to 63 characters from `a-z`, digits, `_`, `.`, `:` and `-` | fails compilation |
| Declaring the queue twice, or a param twice | fails compilation |
| A param named `run_at` or `priority` | fails compilation |
| Param types | must round-trip through JSON |

Keep payloads small: store an id and load the record in `perform`.

## Failed runs retry by rule {#c-coldbrew-retry}

`retry_on` takes an exception class, `attempts`, `backoff` and `base`. `attempts` counts every run, the first included, except runs that maintenance released after their process died.

- `:exponential`: waits base * 2**(attempt - 1)
- `:linear`: waits base * attempt

Rules on the job come first, then rules on its abstract parents, then global rules. The first matching rule wins.

**Application boot · a rule for every job**

```crystal
Caramel::ColdBrew::Job.retry_on Socket::ConnectError,
  attempts: 6, backoff: :linear, base: 3.seconds
```

| Condition | Outcome |
| --- | --- |
| `perform` raises | rolls back its transaction; Cold Brew chooses a retry rule |
| No rule matches | the job runs 3 times with exponential backoff from 1 second |
| A job whose class name no compiled job claims | fails at once, without retries |
| After the last run | the job is failed |
| A failed row | keeps the error’s class, message and first backtrace lines in `last_error`, up to 4,000 characters; status and hooks expose only the class |

[Read status and observe failures →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

## Enqueue joins the business transaction {#c-coldbrew-enqueue}

`enqueue` takes one keyword per param, plus `run_at` and `priority`. It returns the job’s `Int64` id.

**Inside an action or another job**

```crystal
SugarORM::Repo.transaction do
  invite = Invite.create!(email: "elena@acme.com")
  SendInvitation.enqueue(invite_id: invite.id)
end

id = SendInvitation.enqueue(invite_id: 42, run_at: 10.minutes.from_now, priority: 5)
SendInvitation.enqueue(db, invite_id: 42, note: "resend")
```

| Condition | Outcome |
| --- | --- |
| An unknown keyword or a mistyped value | fails compilation at the call |
| `enqueue` inside `SugarORM::Repo.transaction` | commits or rolls back with the business write, because the row is written through `SugarORM::Repo`’s current connection |
| `run_at` | defaults to now; a job runs once it is due |
| A higher `priority` | runs first; the default is 0 |
| Equal priorities | run in id order |
| `enqueue(db, …)` with a `SugarORM::Handle` first | writes on that handle, such as a spec’s `db` |

## A renamed job keeps its queued rows {#c-coldbrew-rename}

A row stores the job’s fully qualified class name, and a worker runs the compiled job of that name. `enqueue` always stores the current name, so after you rename or move a class, rows queued before the deploy still carry the old one. List the old names on the class that replaced it.

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

| Condition | Outcome |
| --- | --- |
| A row queued under any name in `renamed_from` | runs that class with its stored params and its retry rules |
| `renamed_from` that is not string literals of fully qualified class names | fails compilation |
| `renamed_from` declared more than once for a job | fails compilation |
| `renamed_from` on an abstract parent | fails compilation |
| The job’s own class, or a name that is another job’s class or alias, in `renamed_from` | fails compilation |
| `Caramel::ColdBrew.unknown_queued_class_names(db)` | returns the sorted class names of waiting rows, neither locked, finished nor failed, that this binary compiles neither as a job nor as an alias; empty when every queued job can run |
| `work` and `migrate` with such names | log a warning naming them and carry on |

Keep an old name until no row carries it. Because those commands only warn, run the new binary’s `migrate` before the old one stops, and read the list from a deploy script that should fail on it.

**Application boot or a deploy script**

```crystal
names = Caramel::ColdBrew.unknown_queued_class_names(db)
abort "Stranded jobs: #{names.join(", ")}" unless names.empty?
```

## serve and work run the workers {#c-coldbrew-run}

The application binary’s `serve` command starts Cold Brew beside the HTTP server. Its `work` command starts the same workers, maintenance and schedules without HTTP. Both read queue settings from the environment, and `work`’s flags replace them.

| Setting | Meaning |
| --- | --- |
| `CARAMEL_WORKER_QUEUES` | Comma-separated queue names, each once; defaults to default |
| `CARAMEL_WORKER_CONCURRENCY` | Fibers per queue; defaults to 4 |
| `--queues=NAMES` | work only: replaces CARAMEL_WORKER_QUEUES |
| `--concurrency=N` | work only: replaces CARAMEL_WORKER_CONCURRENCY |
| `--no-scheduler` | work only: leaves every schedule to another process |

**Terminal · compiled application**

```bash
./bin/bookshelf work --queues=default,mailers --concurrency=4
```

**Expect:** Workers claim jobs from `default` and `mailers` with four fibers each. On SIGTERM they stop claiming, and in-flight jobs finish before the process exits.

**Terminal · compiled application**

```bash
./bin/bookshelf work --queues=default --no-scheduler
```

**Expect:** Workers claim jobs from `default` only and leave every schedule to another process; maintenance still runs here.

| Condition | Outcome |
| --- | --- |
| `work` with pending migrations, or with `CARAMEL_ENV=test` | refuses to start |
| `serve` under test | starts no workers |
| Invalid worker settings | stop the process before it connects |
| Concurrency per queue | is limited to 31 divided by the number of queues |
| The workers’ connection pool | holds one connection per fiber plus one, up to 32, so jobs never wait for request connections |
| SIGTERM or SIGINT | workers stop claiming jobs; in-flight jobs and schedule blocks finish before the process exits |

Maintenance runs every 60 seconds in every process, even with `--no-scheduler`.

| Condition | Outcome |
| --- | --- |
| A lock older than 15 minutes whose database session has ended | is released, so that job runs again |
| A job released a third time | is failed with `AbandonedJob` and its failure hooks run; each release is counted apart from `attempts` |
| Expired cache entries | are deleted |
| Daily job partitions | are created from today through seven days ahead, in UTC |
| A partition that ended more than 7 days ago and holds only finished or failed jobs | is dropped; `status` then returns nil for those jobs |

## A schedule runs once per period {#c-coldbrew-every}

`Caramel::ColdBrew.every(span, name)` declares a block that runs once per period. Declare schedules at boot, before `serve` or `work` starts.

**Application boot**

```crystal
Caramel::ColdBrew.every(1.hour, "nightly-cleanup") { CleanupJob.enqueue }
```

| Condition | Outcome |
| --- | --- |
| Every process | ticks each schedule, but a database lease lets one process run the block per period |
| The block | runs inside the lease’s transaction, so its writes commit with the lease |
| A span under 1 second, or a blank or repeated name | raises ArgumentError |
| A block that raises | is logged and tried again after its span or one minute, whichever is shorter |

## Notifications arrive at most once {#c-coldbrew-pubsub}

`publish(channel, payload)` sends a string with PostgreSQL `pg_notify` on the current Repo connection.

**Inside a job’s perform method**

```crystal
SugarORM::Repo.transaction do
  Caramel::ColdBrew.publish("board_#{board_id}", board_id.to_s)
end
```

| Condition | Outcome |
| --- | --- |
| `publish` inside a transaction | delivers the notification only when the transaction commits |
| A payload over 8,000 bytes, or a channel name outside 1 to 63 characters from the queue-name set | raises ArgumentError; publish an id and read the record instead |

| Form | Behaviour |
| --- | --- |
| `subscribe(channel) { \|updates\| … }` | Creates a `Channel(String)` and unsubscribes when the block ends |
| `subscribe(channel, subscriber)` | Delivers into your channel until `unsubscribe`, a closed channel, or the end of the fiber that subscribed |

A streaming action’s subscription therefore ends with its stream.

**Inside an action’s handle method**

```crystal
stream "text/event-stream" do |io|
  Caramel::ColdBrew.subscribe("board_#{id}") do |updates|
    loop { Caramel::SSE.write(io, event: "BoardUpdated", data: updates.receive) }
  end
end
```

| Condition | Outcome |
| --- | --- |
| `subscribe` in a process without a broker (`serve` and `work` start one; elsewhere set `Caramel::ColdBrew.broker = Caramel::ColdBrew::Broker.new(database_url)` first) | raises `Caramel::ColdBrew::ConfigurationError` |
| Delivery | is at most once; each subscriber receives payloads in publish order |
| A payload not received within 1 second, a payload beyond 10,000 waiting, or a notification sent while the broker reconnects | is dropped |

## The cache stores strings {#c-coldbrew-cache}

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

| Call | Returns |
| --- | --- |
| `write(key, value, expires_in)` | Inserts or replaces; nil expires_in keeps the entry |
| `read(key)` | The value, or nil when missing or expired |
| `fetch(key, expires_in) { … }` | The cached value, else the block’s value, written |
| `delete(key)` | True when an entry was removed |
| `clear` | Deletes every entry |
| `vacuum` | Deletes expired entries and returns the count |

| Condition | Outcome |
| --- | --- |
| A zero or negative `expires_in` | raises ArgumentError |
| Maintenance | vacuums expired entries every minute |

Keep only values you can compute again.

Prove it

## Drain queues in specs {#c-coldbrew-test}

Specs run no workers. `Caramel::ColdBrew.drain_queue!(db, queue)` runs the queue’s due jobs synchronously on `db`, including jobs that those jobs enqueue. It returns the number of runs.

| Condition | Outcome |
| --- | --- |
| On a spec’s transaction | each job runs in a savepoint |
| A failed job | follows its retry rule and does not run again in the same drain |
| A failed job in `drain_queue!` | raises `DrainFailure`, listing every failed run |
| A failed job in `drain_queue` | does not raise |
| `include_scheduled: true` | runs jobs that are not yet due |
| A drain that has run 1,000 jobs while more are still due | raises `DrainLimitExceeded` |

**Inside a Corretto session · after enqueueing**

```crystal
Caramel::ColdBrew.drain_queue!(db, "mailers")
Caramel::ColdBrew.status(db, id).not_nil!.state
  .should eq(Caramel::ColdBrew::JobState::Finished)
```

**Passing:** The job is `Finished`. A failed run makes `drain_queue!` raise `DrainFailure`, listing every failed run.

[Test requests with Corretto →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

[← SugarORM](https://caramelize.dev/docs/0.14.0/sugarorm/index.md) · [Test it →](https://caramelize.dev/docs/0.14.0/corretto/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/cold-brew/
