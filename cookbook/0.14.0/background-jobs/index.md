Cookbook / Background work

# Give a task its own time.

Enqueue typed jobs with your data, inspect their status, and run Cold Brew workers with or without a web server.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

## Enqueue in the business transaction {#c-job-transaction}

A job extends `Caramel::ColdBrew::Job`, declares typed payload fields with `param`, and implements `perform`. Call its `enqueue` method inside `SugarORM::Repo.transaction` to commit or roll back the queue row with the business write. Keep payloads small and choose a retry rule for the work.

## Read status through the public API {#c-job-status}

**Inside a Repo connection · id returned by enqueue**

```crystal
if status = Caramel::ColdBrew.status(id)
  puts status.state
  puts status.attempts
  puts status.run_at
end
```

`statuses(ids)` reads a batch. The states are Scheduled, Queued, Running, Retrying, Finished, and Failed. Status includes queue, class name, attempts, timestamps, and the last error’s class. Error messages and backtraces stay in the database. Once retention removes a job’s partition, `status` returns nil.

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

Worker hooks run after the transition commits, each in its own transaction. Keep them short; a failed hook rolls back its own writes and is logged without stopping the worker. Maintenance releasing a dead process’s lock does not fire a failure hook. PubSub notifications are at most once, so reconnecting clients should read durable status again.

## Run a worker-only process {#c-job-worker}

The application’s `serve` command starts Cold Brew. The same compiled binary accepts `work` without starting HTTP. Replace `bookshelf` with your application binary.

**Terminal · compiled application**

```bash
./bin/bookshelf work --queues=default,mailers --concurrency=4
./bin/bookshelf work --queues=default --no-scheduler
```

The flags override `CARAMEL_WORKER_QUEUES` and `CARAMEL_WORKER_CONCURRENCY`. Use `--no-scheduler` when another process owns recurring schedules. Work refuses pending migrations and test mode, and lets in-flight jobs finish on SIGTERM or SIGINT.

A worker starts in the default locale. If a job produces translated output, carry `Caramel.language` in a locale payload field and wrap the work in `Caramel::I18n.with`. [Carry language into background work →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

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
> Jobs run at least once. Database writes commit with completion, but an external call can repeat if the process dies or the commit fails afterwards. Send a stable identifier and have the receiving service deduplicate it. A complete recipe still needs the job class, enqueueing action, rollback and retry cases.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Test the response and its effects →](https://caramelize.dev/docs/0.14.0/testing-html/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/background-jobs/
