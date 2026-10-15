Cookbook / Files

# Upload and keep a file.

Bind an upload to a typed contract field and read it for the length of one request. Keeping it after the request is not covered yet.

Recipe needs validation · Target: 0.16.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Status | Needs validation: Caramel ships no storage adapter, so the recipe stops at the request |
| Needs | A contract field typed `Caramel::UploadedFile` |
| You will have | A file bound to a temporary file for the length of the request, within the 64 MiB budget the security reference lists |
| Proved by | Nothing yet on this page; the rules below are proved by the framework’s own specs |

## Where the change goes {#c-uploads-files}

- `app/actions/`: Contract binds the file
- `spec/requests/`: Success and rejection checks

## What is supported today {#c-uploads-supported}

These rules run in Caramel 0.16.0 and its specs prove them.

| Condition | Outcome |
| --- | --- |
| A contract field typed `Caramel::UploadedFile` | binds one multipart file part of that name |
| The bound file | has `filename`, `content_type`, `path` and `size`; `path` is a temporary file |
| The request ends | deletes the temporary file; copy it elsewhere to keep it |
| A route whose contract has no `UploadedFile` field | stores no file; a file part sent to it answers 422 with `Unknown field: cover` |
| A POST form whose `_method` reaches a route with an `UploadedFile` field | stores the file |
| More than 128 file parts in one request | answers 413 |
| An `UploadedFile` field with a default | fails compilation |
| A Corretto request with `files:`, such as `Corretto.upload("spec/fixtures/cover.png", "image/png")` | sends a multipart form |

[Read the upload limits →](https://caramelize.dev/docs/0.16.0/security/index.md)[Send files from a spec →](https://caramelize.dev/docs/0.16.0/corretto/index.md)

## Not covered yet {#c-uploads-gaps}

- Validate the file and its size Application rule
- Persist beyond the request Needs example
- Serve with intended access rules Needs example
- Clean up failed or replaced uploads Needs example
- Prove success and rejection Corretto spec

Prove it

## Prove success and rejection {#c-uploads-prove}

**Terminal · inside the application**

```bash
frappe corretto
```

**Passing:** A Corretto example accepts a valid file and rejects one that breaks the application’s file rule. This recipe has no such example yet.

> Needs validation **A parser is only one part of file storage**
>
> This recipe does not claim a storage adapter or offer untested persistence code. The complete recipe must establish that path first.

[← All recipes](https://caramelize.dev/cookbook/0.16.0/) · [Send files from a spec →](https://caramelize.dev/docs/0.16.0/corretto/index.md)

Caramel 0.16.0 · https://caramelize.dev/cookbook/0.16.0/uploads/
