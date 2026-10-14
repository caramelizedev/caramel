Cookbook / Files

# Upload and keep a file.

Multipart parsing exists. A dependable recipe also needs to show where the file lives after the request ends.

Recipe needs validation · Target: 0.14.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Status | Needs validation: this preview claims no supported storage adapter |
| Needs | A contract field typed `Caramel::UploadedFile` |
| You will have | Today, a file bound to a temporary file scoped to the request, within a 64 MiB total upload cap |
| Proved by | A Corretto spec for success and rejection |

## Where the change goes {#c-upload-files}

- `app/actions/`: Contract binds the file
- `spec/requests/`: Success and rejection checks

## What is supported today {#c-upload-supported}

| Part | Today |
| --- | --- |
| Binding | Typed contracts can bind `Caramel::UploadedFile` |
| Storage | Multipart files stream to temporary files scoped to the request |
| Size cap | 64 MiB total upload cap in the current implementation |

## What the recipe must demonstrate {#c-upload-work}

- Validate the file and its size Application rule
- Persist beyond the request Needs example
- Serve with intended access rules Needs example
- Clean up failed or replaced uploads Needs example
- Prove success and rejection Corretto spec

Prove it

## Prove success and rejection {#c-upload-prove}

**Terminal · inside the application**

```bash
frappe corretto
```

**Passing:** A Corretto example accepts a valid file and rejects one that breaks the application’s file rule. This recipe has no such example yet.

> Needs validation **A parser is only one part of file storage**
>
> This preview does not claim a supported storage adapter or offer untested persistence code. The complete recipe must establish that path first.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Find the application boundaries →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/uploads/
