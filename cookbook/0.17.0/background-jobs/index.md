Cookbook / Background work

# Give a task its own time.

Enqueue a typed job inside the transaction that needs it, drain it in a request spec, and run Cold Brew workers without a web server.

Proved by scripts/check page-jobs · Target: 0.17.0

| Contract | Value |
| --- | --- |
| Needs | The machine setup of [Your first application](https://caramelize.dev/docs/0.17.0/getting-started/index.md); the recipe generates its own Book resource |
| You will have | An `ImportBook` job on the `imports` queue, an action that enqueues it inside `SugarORM::Repo.transaction`, a request spec that drains the queue, reads the job’s status and rolls an enqueue back, and a worker started on both queues |
| Status | Run end to end by `scripts/check page-jobs` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-jobs-files}

- `app/jobs/import_book.cr`: The typed job
- `app/actions/imports/create.cr`: Enqueues in a transaction
- `config/routes.cr`: The import route
- `spec/requests/imports_spec.cr`: Drain, status, rollback

## Create the application and its Book {#c-jobs-create}

The application is `bookshelf`. The job writes books, so the Book resource comes first.

1. **Generate and migrate**

   **Terminal · after machine setup**

   ```bash
   frappe new bookshelf
   cd bookshelf
   frappe make resource Book title:string author:string
   frappe migrate
   ```

   **Expect:** `frappe new` prints `Created bookshelf.`, then `bookshelf is configured at https://bookshelf.caramel`. `make resource` prints `Generated PATH` for each file it writes, then `Run frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.` `frappe migrate` prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## Write the job {#c-jobs-job}

A job is a struct under `Caramel::ColdBrew::Job`: `queue` names its queue, each `param` is one typed field of its payload, and `perform` does the work. `ImportBook` creates one book. A job runs at least once: a job that calls another service sends a stable identifier, so the receiver can drop a repeat.

1. **Declare the queue, the params and perform**

   **app/jobs/import_book.cr**

   ```crystal
   module App
     struct ImportBook < Caramel::ColdBrew::Job
       queue "imports"
       param title : String
       param author : String

       def perform
         App::Book.create!(title: title, author: author)
       end
     end
   end
   ```

   **Expect:** The params give the job a generated `ImportBook.enqueue(title:, author:)`, which returns the job id as `Int64`; `enqueue` takes no `queue:` keyword, the class’s `queue` line decides. A job without that line is on `default`. A failed run follows the default retry rule, 3 runs with exponential backoff from 1 second, until a `retry_on` line replaces it. The names a queue may have, `retry_on`, `renamed_from` and the params that fail compilation are the job rules. [Read the job rules →](https://caramelize.dev/docs/0.17.0/cold-brew/index.md)

## Enqueue in the business transaction {#c-jobs-transaction}

`enqueue` writes the queue row through the connection `SugarORM::Repo.transaction` holds. The row commits with the rows the block writes and rolls back with them; a job never runs for a write that was rolled back. The action answers 202 with a fragment that names the job id.

1. **Write the action**

   **app/actions/imports/create.cr**

   ```crystal
   module App::Imports
     struct Create < App::ApplicationAction
       contract do
         field title : String
         field author : String
       end

       def handle(contract : Contract)
         id = SugarORM::Repo.transaction do
           App::ImportBook.enqueue(title: contract.title, author: contract.author)
         end
         morph("#imports", with: "Import #{id} queued", status: 202)
       end
     end
   end
   ```

   **Expect:** A browser that posts a title and an author gets status 202 and an `hx-partial` for `#imports` that reads `Import N queued`, N the id `enqueue` returned. The book does not exist yet: the job creates it when a worker, or a spec’s drain, runs it.
2. **Route it**

   **config/routes.cr · inside Caramel::Router.draw**

   ```crystal
   post "/imports", App::Imports::Create
   ```

   **Terminal · inside the application**

   ```bash
   frappe routes imports
   ```

   **Expect:** Lists `POST /imports App::Imports::Create title:String author:String`.

## Drain the queue in a spec {#c-jobs-check}

Corretto starts no workers. `Caramel::ColdBrew.drain_queue!(db, "imports")` runs every due job of the queue on the example’s connection and returns how many ran, so the first example asserts the book after the drain and the job’s state through `Caramel::ColdBrew.status`. The second example enqueues inside a transaction it rolls back: no queue row survives, and the drain returns 0.

1. **Write the examples**

   **spec/requests/imports_spec.cr**

   ```crystal
   require "../spec_helper"

   describe "Importing a book" do
     it "queues the import, and the book exists once the queue drains" do
       Corretto.session do |client, db|
         queued = client.post("/imports", headers: {"HX-Request" => "true"},
           params: {"title" => "Dune", "author" => "Frank Herbert"})
         queued.should have_status(202)
         queued.should render_partial("#imports")
         db.should_not have_row(App::Book, title: "Dune")
         Caramel::ColdBrew.drain_queue!(db, "imports").should eq(1)
         db.should have_row(App::Book, title: "Dune", author: "Frank Herbert")
         Caramel::ColdBrew.drain_queue!(db, "imports").should eq(0)
         id = db.query_one("SELECT max(id) FROM caramel_jobs", as: Int64)
         status = Caramel::ColdBrew.status(db, id)
         status.try(&.state).should eq(Caramel::ColdBrew::JobState::Finished)
       end
     end

     it "keeps no queue row when the transaction rolls back" do
       Corretto.session do |_client, db|
         SugarORM::Repo.transaction do
           App::ImportBook.enqueue(title: "Dropped", author: "Nobody")
           SugarORM::Repo.rollback
         end
         Caramel::ColdBrew.drain_queue!(db, "imports").should eq(0)
       end
     end
   end
   ```

   **Expect:** `frappe corretto` runs both examples; the proof below shows its output. The drain rules, what `status` and `statuses` return, the six `JobState` values, and the retry and failure hooks are listed in the reference. [Read status, hooks and drain →](https://caramelize.dev/docs/0.17.0/cold-brew/index.md)

## Run a worker-only process {#c-jobs-worker}

The compiled application takes `serve` and `work`; `work` runs the queues without HTTP. `frappe dev` and the one-shot commands compile to `.caramel/application`; `bin/bookshelf` exists only in the tarball `frappe build` writes under `.caramel/build/`, beside `public/`, and the template git-ignores `/bin/`. [Build the artifact →](https://caramelize.dev/docs/0.17.0/deployment/index.md)

`work` reads `DATABASE_URL` and `CARAMEL_ENV`, which is `production` when unset, and needs the migrations applied; it reads no `APP_SECRET` or `APP_ORIGIN`.

1. **Start workers on both queues**

   **Terminal · where the artifact is unpacked**

   ```bash
   bin/bookshelf work --queues=default,imports --concurrency=4
   ```

   **Expect:** Prints `Bookshelf worker is ready: queues default, imports; concurrency 4; scheduler on` and runs until SIGTERM or SIGINT. With a migration pending it prints `Pending migrations. Run frappe migrate first.` and exits; under `CARAMEL_ENV=test` it prints `Specs run no workers; drain queues with Caramel::ColdBrew.drain_queue!` and exits. `--no-scheduler` ends the ready line with `scheduler off`. The worker settings, the concurrency limit and the shutdown rules are listed in the reference. [Read the worker settings →](https://caramelize.dev/docs/0.17.0/cold-brew/index.md)

A worker starts in the default locale. If a job produces translated output, carry `Caramel.language` in a locale payload field and wrap the work in `Caramel::I18n.with`. [Carry language into background work →](https://caramelize.dev/docs/0.17.0/internationalization/index.md)

Prove it

## Prove the job {#c-jobs-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` and `frappe lint` exit 0. `frappe corretto` runs the import examples beside the generated book spec and ends with `Corretto: 1 of 1 workers passed`: the book exists only after the drain, the drained job reads `Finished`, and the rolled-back enqueue left nothing to drain.

> Proved **Run end to end by a check.**
>
> `scripts/check page-jobs` creates `bookshelf`, generates and migrates the Book resource, copies the job, the action, the route and the spec at the steps above, lists the route, starts `work --queues=default,imports --concurrency=4` on the compiled application until it prints its ready line, and runs `frappe check`, `frappe corretto` and `frappe lint`.

[← All recipes](https://caramelize.dev/cookbook/0.17.0/) · [Test the response and its effects →](https://caramelize.dev/docs/0.17.0/testing-html/index.md)

Caramel 0.17.0 · https://caramelize.dev/cookbook/0.17.0/background-jobs/
