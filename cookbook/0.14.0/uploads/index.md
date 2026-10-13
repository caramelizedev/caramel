Cookbook / Files

# Upload and keep a file.

Multipart parsing exists. A dependable recipe also needs to show where the file lives after the request ends.

Recipe needs validation · Target: 0.14.0 · Not yet recipe-tested

## What is supported today {#c-upload-supported}

Typed contracts can bind `Caramel::UploadedFile`. Multipart files stream to temporary files scoped to the request, with a 64 MiB total upload cap in the current implementation.

## What the recipe must demonstrate {#c-upload-work}

- Validate the file and its size Application rule
- Persist beyond the request Needs example
- Serve with intended access rules Needs example
- Clean up failed or replaced uploads Needs example
- Prove success and rejection Corretto spec

> **A parser is only one part of file storage**
>
> This preview does not claim a supported storage adapter or offer untested persistence code. The complete recipe must establish that path first.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Find the application boundaries →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/uploads/
