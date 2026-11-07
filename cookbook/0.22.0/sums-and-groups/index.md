Cookbook / Domain

# Sum and group a context’s rows.

Declare a period’s total and a total per heading on the aggregate with sums and groups, each one statement that keeps the tenant predicate and leaves removed rows out.

Proved by scripts/check page-sums · Target: 0.22.0

| Contract | Value |
| --- | --- |
| Needs | A Caramel installation set up as in [Your first application](https://caramelize.dev/docs/0.22.0/getting-started/index.md); the recipe creates `ledger`, its `App::Account` tenant and its `Ledger` domain ([SweetTalk](https://caramelize.dev/docs/0.22.0/sweettalk/index.md)) |
| You will have | A `Journal` aggregate whose lines are posted to one period, one `sums` that adds a period’s posted lines up, two `groups` that total them per heading, and a domain spec for each |
| Status | Run end to end by `scripts/check page-sums` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-sums-files}

- `app/domain/ledger.cr`: Journal, the sums and groups
- `db/migrations/`: Tables from the diff
- `spec/support/ledger.cr`: Posts or drafts a journal
- `spec/domain/ledger_spec.cr`: The sum and the groups

## Decide before you generate {#c-sums-choices}

- **Declare the sum on the aggregate that holds the rows**

  `sums` and `groups` are declared beside `finds` and `counts`, with the same `where:` and `satisfying:`, and `of:` names the attribute they add up: one of the aggregate’s own by symbol, or one of its entities’ as `Line.amount`. Each runs one `SELECT` over the live rows of the bound tenant, so no SQL and no tenant predicate is written by hand. The attribute is a whole number, a `Float64`, or a value that wraps a whole number or a decimal and has no bound a sum could break: `Cents` here has none, because a credit is negative.
- **Keep a projection for a sum read on every request**

  A `sums` adds its rows up when it is called. A total the application shows on every request, or one grouped by a key the attributes do not hold, is a projection keyed by what it groups by and kept current by `whenever` ([SweetTalk](https://caramelize.dev/docs/0.22.0/sweettalk/index.md), React).

## Create the application, its tenant and its domain {#c-sums-start}

The application is `ledger`. Its books belong to an account, so the tenant comes first, and `frappe make domain` then writes `tenant App::Account` into the domain it generates.

1. **Create the application**

   **Terminal · after machine setup**

   ```bash
   frappe new ledger
   cd ledger
   ```

   **Expect:** Prints `Created ledger.`, then `ledger is configured at https://ledger.caramel`.
2. **Make Account the tenant**

   **Terminal · inside the application**

   ```bash
   frappe make tenancy Account
   ```

   **Expect:** Prints `Generated PATH` for each file it writes or edits, `app/models/account.cr` among them, then `Next: run frappe migrate and open /accounts/new.`
3. **Apply the tenant’s migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`
4. **Generate the domain**

   **Terminal · inside the application**

   ```bash
   frappe make domain Ledger Books --means="what each heading was posted in each period"
   ```

   **Expect:** Prints `Generated` for each of the four files it writes, `app/domain/ledger.cr` and `spec/domain/ledger_spec.cr` among them, then `Next: write the domain in app/domain/ledger.cr, then run frappe db diff --name create_ledger and frappe migrate.`

## Declare the journal, its sums and its groups {#c-sums-journal}

A `Journal` is the aggregate: lines added under headings, then posted once. The three queries at its end are the reports. `posted_in` adds up `Line.amount` over the posted journals of one period and returns a `Cents`; `by_heading_in` adds the same lines up once per heading; `by_heading` does so over every period. Each keeps `where:` on the journal, `period` and `state`, and groups by an attribute of the entity it adds up. Replace the generated `app/domain/ledger.cr` with this file.

**app/domain/ledger.cr**

```crystal
# The Ledger domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
# context, value, aggregate, event and sums, exist only inside this module.
module App::Ledger
  include SweetTalk
  tenant App::Account

  context Books, subdomain: :core, means: "what each heading was posted in each period" do
    value Cents, Int64, means: "an amount in minor units; a credit is negative"
    value Heading, String, length: 1..40, means: "what an amount is posted under, such as sales"
    value Period, String, matches: /\A\d{4}-(0[1-9]|1[0-2])\z/,
      means: "a calendar month written YYYY-MM"

    aggregate Journal, means: "the lines posted together to one period" do
      has period : Period
      has lines : Array(Line)
      moves open >> posted

      entity Line, means: "one amount under one heading" do
        has heading : Heading
        has amount : Cents
      end

      event Posted, period : Period, lines : Array(Line),
        means: "the journal's lines reached the books"

      factory open(period : Period) do
      end

      to add(heading : Heading, amount : Cents) do
        refuse "A posted journal takes no more lines." if posted?
        @lines << Line.new(heading, amount)
      end

      to post do
        refuse "The journal is already posted." if posted?
        refuse "An empty journal cannot be posted." if lines.empty?
        posted!
        emit Posted, period: period, lines: lines
      end

      sums posted_in(period : Period), of: Line.amount, where: {period: period, state: :posted}
      groups by_heading_in(period : Period), of: Line.amount, by: Line.heading,
        where: {period: period, state: :posted}
      groups by_heading, of: Line.amount, by: Line.heading, where: {state: :posted}
    end
  end
end
```

Each query runs one statement: a `sum` over `books_journal_lines` whose `journal_id` is in a subquery over `books_journals` with the `where:` conditions, the tenant’s and the removed rows’ exclusion, so a drafted journal and another tenant’s lines are never added. PostgreSQL returns the sum as text, and `Cents.new` builds the value from it; a sum no row matches is `Cents.new(0)`. A `groups` returns `{by: Heading, total: Cents}` rows ordered by the stored heading, so `cash` comes before `sales`.

| Condition | Outcome |
| --- | --- |
| `Journal.posted_in(period)` for a period no journal was posted to | returns `Cents.new(0)`, the sum of no rows |
| `Journal.by_heading` in a tenant with no posted journal | returns `[]` |
| A sum past `Int64` | raises `ArgumentError` from `to_i64` |
| `sums` of a value with an upper bound, or a lower bound other than 0 | fails compilation |
| `groups` that adds up `Line.amount` and groups by `:period`, an attribute of the journal | fails compilation: narrow with `where:` instead |
| A `finds` block that sums, counts or groups its rows, or names SugarORM | fails compilation |

1. **Derive the migration**

   **Terminal · inside the application**

   ```bash
   frappe db diff --name create_ledger
   ```

   **Expect:** Prints `Wrote` and the path of one migration ending in `_create_ledger.cr`. It creates `books_journals` and `books_journal_lines`, each with an `account_id`.
2. **Apply the migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## Specify the sums {#c-sums-specs}

The helpers open one journal of amounts by heading and post it, or leave it open as a draft. Nothing follows `Posted`, so no queue is drained. The examples run in a tenant through `account(db, slug)`, the helper `frappe make tenancy` wrote, and the last one posts to two tenants and reads the groups from the second.

**spec/support/ledger.cr**

```crystal
# Builders the ledger's specs share.
module LedgerSpec
  extend self

  def period(text : String) : App::Ledger::Books::Period
    App::Ledger::Books::Period.new(text)
  end

  def heading(text : String) : App::Ledger::Books::Heading
    App::Ledger::Books::Heading.new(text)
  end

  # Opens one journal of *amounts* by heading to *period*, and leaves it open.
  def draft(period : String, amounts : Hash(String, Int32)) : Nil
    journal = App::Ledger::Books::Journal.open(self.period(period))
    amounts.each do |heading, amount|
      journal.add(heading(heading), App::Ledger::Books::Cents.new(amount))
    end
  end

  # Opens one journal of *amounts* by heading to *period*, and posts it.
  def post(period : String, amounts : Hash(String, Int32)) : Nil
    journal = App::Ledger::Books::Journal.open(self.period(period))
    amounts.each do |heading, amount|
      journal.add(heading(heading), App::Ledger::Books::Cents.new(amount))
    end
    journal.post
  end
end
```

**spec/domain/ledger_spec.cr · replaces the generated spec**

```crystal
require "../spec_helper"
require "../support/ledger"

describe App::Ledger do
  it "adds up a period's posted lines" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100, "fees" => 7})
        LedgerSpec.draft("2026-11", {"fees" => 50})
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-10")).raw.should eq(0)
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-11")).raw.should eq(7)
        App::Ledger::Books::Journal.posted_in(LedgerSpec.period("2026-12")).raw.should eq(0)
      end
    end
  end

  it "groups a period's posted lines by heading" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100, "fees" => 7})
        LedgerSpec.draft("2026-11", {"fees" => 50})
        rows = App::Ledger::Books::Journal.by_heading_in(LedgerSpec.period("2026-11"))
        rows.map { |row| {row[:by].raw, row[:total].raw} }
          .should eq([{"cash", 100}, {"fees", 7}, {"sales", -100}])
      end
    end
  end

  it "groups for the bound tenant only" do
    Corretto.session do |_client, db|
      Caramel::Tenancy.with(account(db, "acme")) do
        LedgerSpec.post("2026-10", {"sales" => -500, "cash" => 500})
        LedgerSpec.post("2026-11", {"sales" => -100, "cash" => 100})
      end
      Caramel::Tenancy.with(account(db, "globex")) do
        LedgerSpec.post("2026-10", {"sales" => -9, "cash" => 9})
        rows = App::Ledger::Books::Journal.by_heading
        rows.map { |row| {row[:by].raw, row[:total].raw} }.should eq([{"cash", 9}, {"sales", -9}])
      end
    end
  end
end
```

1. **Run the domain spec**

   **Terminal · inside the application**

   ```bash
   frappe corretto spec/domain/ledger_spec.cr
   ```

   **Expect:** Prints `[w1] 3 examples, 0 failures, 0 errors, 0 pending`, then `Corretto: 1 of 1 workers passed`.

Prove it

## Prove the sums {#c-sums-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` exits 0. `frappe corretto` runs the three ledger examples beside the generated account examples and ends with `Corretto: 1 of 1 workers passed`. `frappe lint` exits 0.

> Proved **Run end to end by a check.**
>
> `scripts/check page-sums` creates `ledger`, makes Account its tenant, migrates, generates the domain, copies these files at the steps above, derives and applies the migration, runs the domain spec and the proof, and the website build holds every snippet on this page to those files.

[← All recipes](https://caramelize.dev/cookbook/0.22.0/) · [Read the SweetTalk guide →](https://caramelize.dev/docs/0.22.0/sweettalk/index.md)

Caramel 0.22.0 · https://caramelize.dev/cookbook/0.22.0/sums-and-groups/
