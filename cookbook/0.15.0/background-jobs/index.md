Cookbook / Background work

# Give a task its own time.

Enqueue typed jobs with your data, inspect their status, and run Cold Brew workers with or without a web server.

Draft recipe · Target: 0.15.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Needs | An application whose migrations are applied (`work` refuses pending migrations) |
| You will have | Jobs enqueued in the business transaction, readable status, retry and failure hooks, and workers that run without HTTP |
| Proved by | `frappe corretto`, draining due jobs with `drain_queue!` |

## Where the change goes {#c-job-files}

- `app/jobs/`: Typed job classes
- `app/actions/`: Enqueueing action
- `bin/bookshelf`: Worker-only process
- `spec/`: Drain and status checks

## Enqueue in the business transaction {#c-job-transaction}

A job extends `Caramel::ColdBrew::Job`, declares typed payload fields with `param`, and implements `perform`.

| Condition | Outcome |
| --- | --- |
| The transaction commits | the queue row commits with the business write |
| The transaction rolls back | the queue row rolls back with it |

Call `enqueue` inside `SugarORM::Repo.transaction`. Keep payloads small and choose a retry rule for the work. [Read the Cold Brew reference →](https://caramelize.dev/docs/0.15.0/cold-brew/index.md)

## Read status through the public API {#c-job-status}

**Inside a Repo connection · id returned by enqueue**

```crystal
if status = Caramel::ColdBrew.status(id)
  puts status.state
  puts status.attempts
  puts status.run_at
end
```

| Name | Meaning |
| --- | --- |
| `status(id)` | One job’s status |
| `statuses(ids)` | The statuses of a batch of ids |
| States | Scheduled, Queued, Running, Retrying, Finished, Failed |
| Status carries | Queue, class name, attempts, timestamps, and the last error’s class |
| Not in status | Error messages and backtraces; they stay in the database |

| Condition | Outcome |
| --- | --- |
| Retention has removed the job’s partition | `status` returns nil |

## Observe retries and terminal failures {#c-job-hooks}

**Application boot · before workers start**

```crystal
Caramel::ColdBrew.on_retry_scheduled do |event|
  Caramel::ColdBrew.publish("deliveries", event.to_json)
end

Caramel::ColdBrew.on_failed do |event|
  Caramel::ColdBrew.publish("deliveries", event.to_json)
end
```

| Condition | Outcome |
| --- | --- |
| A worker transition commits | the hook runs afterwards, in its own transaction |
| A hook fails | rolls back its own writes, is logged, and the worker keeps running |
| Maintenance releases a dead process’s lock | fires no hook until the job’s third release, when it fails the job with `AbandonedJob` and calls the failure hooks |

Keep hooks short. PubSub notifications are at most once, so reconnecting clients should read durable status again.

## Run a worker-only process {#c-job-worker}

The application’s `serve` command starts Cold Brew. The same compiled binary accepts `work` without starting HTTP. Replace `bookshelf` with your application binary.

1. **Start workers on named queues**

   **Terminal · compiled application**

   ```bash
   ./bin/bookshelf work --queues=default,mailers --concurrency=4
   ```

   **Expect:** Workers start without HTTP on the `default` and `mailers` queues. Pending migrations stop them.
2. **Leave schedules to another process**

   **Terminal · compiled application**

   ```bash
   ./bin/bookshelf work --queues=default --no-scheduler
   ```

   **Expect:** Workers start without the scheduler; another process owns the recurring schedules.

| Flag | Effect |
| --- | --- |
| `--queues=NAMES` | Overrides `CARAMEL_WORKER_QUEUES` |
| `--concurrency=N` | Overrides `CARAMEL_WORKER_CONCURRENCY` |
| `--no-scheduler` | Use when another process owns recurring schedules |

| Condition | Outcome |
| --- | --- |
| `work` with pending migrations | refuses |
| `work` in test mode | refuses |
| SIGTERM or SIGINT | in-flight jobs finish |

A worker starts in the default locale. If a job produces translated output, carry `Caramel.language` in a locale payload field and wrap the work in `Caramel::I18n.with`. [Carry language into background work →](https://caramelize.dev/docs/0.15.0/internationalization/index.md)

## Check observable effects synchronously {#c-job-check}

Corretto does not start workers. Drain due jobs on the example’s database handle, then assert business state, retry status, and hook effects.

**Inside a Corretto session · after enqueueing**

```crystal
Caramel::ColdBrew.drain_queue!(db, "default")
Caramel::ColdBrew.status(db, id).not_nil!.state
  .should eq(Caramel::ColdBrew::JobState::Finished)
```

> **Plan for repeated delivery**
>
> Jobs run at least once. Database writes commit with completion, but an external call can repeat if the process dies or the commit fails afterwards. Send a stable identifier and have the receiving service deduplicate it.

Prove it

## Prove the job {#c-job-prove}

**Terminal · inside the application**

```bash
frappe corretto
```

**Passing:** After `drain_queue!`, the job’s status reads `Finished`, and the examples assert the business state, retry status and hook effects.

> Draft **Written for 0.15.0, not yet run end to end.**
>
> A complete recipe still needs the job class, enqueueing action, rollback and retry cases. It keeps its Draft label until it has been run from a new application to a passing spec.

[← All recipes](https://caramelize.dev/cookbook/0.15.0/) · [Test the response and its effects →](https://caramelize.dev/docs/0.15.0/testing-html/index.md)

Caramel 0.15.0 · https://caramelize.dev/cookbook/0.15.0/background-jobs/
