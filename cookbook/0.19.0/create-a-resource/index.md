Cookbook / Data and forms

# Create a resource.

Generate a book catalog, then make the model, actions, views, and request specs your own.

Proved by scripts/check frappe-project · Target: 0.19.0

| Contract | Value |
| --- | --- |
| Needs | A configured application |
| You will have | A Book model, changeset, migration, actions, views, routes and request spec |
| Status | Run end to end by `scripts/check frappe-project`, from `frappe new` to the passing spec; the options below are proved by the generator’s own specs |
| Proved by | `frappe check` · `frappe corretto spec/requests/books_spec.cr` |

## Where the change goes {#c-crud-files}

- `app/models/book.cr`: The stored shape
- `app/changesets/book.cr`: Rules for writes
- `db/migrations/`: Creates the table
- `app/actions/books.cr`: Shared form helpers
- `app/actions/books/`: Request handling
- `app/views/books/`: Browser presentation
- `config/routes.cr`: Seven routes, inserted
- `config/paths.cr`: Path helpers, inserted
- `spec/requests/books_spec.cr`: Behavior checks

## Decide before you generate {#c-crud-before}

Two choices change what the generator writes. Make them first.

- **A multi-tenant application** The resource belongs to the tenant unless you pass `--central`. [Set up multi-tenancy →](https://caramelize.dev/docs/0.19.0/multi-tenancy/index.md)
- **A translated application** Run `frappe make locale CODE` before resource generation. Frappé then adds typed message calls and default catalog entries. [Set up internationalization →](https://caramelize.dev/docs/0.19.0/internationalization/index.md)

## Generate the feature {#c-crud-build}

Run inside a configured application. Review the generated files and migration before applying it.

1. **Generate the resource**

   **Terminal · inside the application**

   ```bash
   frappe make resource Book title:string author:string
   ```

   **Expect:** Prints `Generated PATH` for each of the 19 files it writes or edits: the seven actions and `app/actions/books.cr`, the five views, the model, the changeset, `db/migrations/…_create_books.cr`, `config/routes.cr`, `config/paths.cr` and `spec/requests/books_spec.cr`, then `Run frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.`
2. **Apply the reviewed migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## Choose the generated surface {#c-crud-options}

| Pass | To get |
| --- | --- |
| `original_url:string:url` | URL validation, a URL input, and valid request-spec samples |
| `--only=create,show` | A smaller resource; create and show are required, and edit needs new and update |
| `--plural=people` | An irregular plural for the table, the routes and the module |
| `:server` | A field the action sets |
| `:unique` | A unique index and constraint checks |

The field types are `string`, `int32`, `int64`, `bool`, `float64` and `time`, each nullable with `?`. [Read the make resource syntax →](https://caramelize.dev/docs/0.19.0/commands/index.md)

Extend the generated spec with your own validation rule and an example that fails that rule.

Prove it

## Prove the behavior {#c-crud-check}

**Terminal · inside the application**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
```

**Passing:** `frappe check` exits 0, and `frappe corretto` runs the generated request spec, which creates, reads, updates and deletes a book and refuses a forged token and an unknown field, then ends with `Corretto: 1 of 1 workers passed`.

> Proved **Run end to end by a check.**
>
> `scripts/check frappe-project` creates an application, generates this resource and two more, migrates, and runs `frappe check`, `frappe lint` and `frappe corretto` on the result.

[← All recipes](https://caramelize.dev/cookbook/0.19.0/) · [Return the same data as JSON →](https://caramelize.dev/cookbook/0.19.0/return-json/index.md)

Caramel 0.19.0 · https://caramelize.dev/cookbook/0.19.0/create-a-resource/
