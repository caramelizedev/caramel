Cookbook / Data and forms

# Create a resource.

Generate a book catalog, then make the model, actions, views, and request specs your own.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Needs | A configured application |
| You will have | A Book model, changeset, actions, views and request spec |
| Proved by | `frappe corretto spec/requests/books_spec.cr` |

## Where the change goes {#c-crud-files}

- `app/models/book.cr`: The stored shape
- `app/changesets/book.cr`: Rules for writes
- `app/actions/books/`: Request handling
- `app/views/books/`: Browser presentation
- `spec/requests/books_spec.cr`: Behavior checks

## Decide before you generate {#c-crud-before}

Two choices change what the generator writes. Make them first.

- **A multi-tenant application** The resource belongs to the tenant unless you pass `--central`. [Set up multi-tenancy →](https://caramelize.dev/docs/0.14.0/multi-tenancy/index.md)
- **A translated application** Run `frappe make locale CODE` before resource generation. Frappé then adds typed message calls and default catalog entries. [Set up internationalization →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

## Generate the feature {#c-crud-build}

Run inside a configured application. Review the generated files and migration before applying it.

1. **Generate the resource**

   **Terminal · inside the application**

   ```bash
   frappe make resource Book title:string author:string
   ```

   **Expect:** Prints a `Generated PATH` line for each file: the five files above, and a migration. Review both before applying anything.
2. **Apply the reviewed migration**

   **Terminal · inside the application**

   ```bash
   frappe migrate
   ```

   **Expect:** Applies the reviewed migration and prints `Applied N migrations.`

## Choose the generated surface {#c-crud-options}

| Pass | To get |
| --- | --- |
| `original_url:string:url` | URL validation, a URL input, and valid request-spec samples |
| `--only=create,show` | A smaller resource; create and show are required, and edit needs new and update |
| `:server` | A field the action sets |
| `:unique` | A unique index and constraint checks |

Prove it

## Prove the behavior {#c-crud-check}

**Terminal · inside the application**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
```

**Passing:** The generated request spec exercises create, read, update, delete, and rejection of invalid requests.

Extend it with your own validation rule and an example that fails that rule.

> Draft **Written for 0.14.0, not yet run end to end.**
>
> The recipe keeps its Draft label until it has been run from a new application to a passing spec.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Return the same data as JSON →](https://caramelize.dev/cookbook/0.14.0/return-json/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/create-a-resource/
