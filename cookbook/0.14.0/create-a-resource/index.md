Cookbook / Data and forms

# Create a resource.

Generate a book catalog, then make the model, actions, views, and request specs your own.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

## Where the change goes {#c-crud-files}

- `app/models/book.cr`: The stored shape
- `app/changesets/book.cr`: Rules for writes
- `app/actions/books/`: Request handling
- `app/views/books/`: Browser presentation
- `spec/requests/books_spec.cr`: Behavior checks

## Generate the feature {#c-crud-build}

Run inside a configured application. Review the generated files and migration before applying it.

**Terminal**

```bash
frappe make resource Book title:string author:string
frappe migrate
```

In a multi-tenant application, the resource belongs to the tenant unless you pass `--central`. [Set up multi-tenancy →](https://caramelize.dev/docs/0.14.0/multi-tenancy/index.md)

For translated resources, run `frappe make locale CODE` before resource generation. Frappé then adds typed message calls and default catalog entries. [Set up internationalization →](https://caramelize.dev/docs/0.14.0/internationalization/index.md)

## Choose the generated surface {#c-crud-options}

`original_url:string:url` adds URL validation, a URL input, and valid request-spec samples. Use `--only=create,show` for a smaller resource; create and show are required, and edit needs new and update. Use `:server` for fields set by the action and `:unique` for a unique index and constraint checks.

## Prove the behavior {#c-crud-check}

**Terminal**

```bash
frappe check
frappe corretto spec/requests/books_spec.cr
```

The generated request spec exercises create, read, update, delete, and rejection of invalid requests. Extend it with your own validation rule and an example that fails that rule.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Return the same data as JSON →](https://caramelize.dev/cookbook/0.14.0/return-json/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/create-a-resource/
