Learn / The Bookshelf path

# Start with something real.

Install Caramel 0.16.0, create a bookshelf, and check the generated feature with real application tests.

| Contract | Value |
| --- | --- |
| Needs | Apple Silicon macOS with Apple Command Line Tools |
| You will have | A `bookshelf` application with a generated Book resource, checked by request specs |
| Status | Steps 02 and 03 and the proof run end to end in `scripts/check frappe-project`; the machine setup in step 01 is not run by a check |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

> **Caramel develops on Apple Silicon macOS and brings its own toolchain.**
>
> Install Apple Command Line Tools first; development dependencies use its C compiler and archiver. `scripts/install-toolchain` supplies the pinned Crystal 1.21.1, PostgreSQL 18.6, Caddy 2.11.4 and CoreDNS 1.14.7, so nothing else is installed by hand. Every page that needs these facts links here.

## 01 · Install the release {#c-learn-setup}

Clone the `v0.16.0` tag and run the six setup commands, each with what it prints, in the [Local environment reference](https://caramelize.dev/docs/0.16.0/local-environment/index.md): the toolchain, the release build, `installations register`, the services, the resolver and ports, and the certificate trust. Then confirm the services from any directory.

**Terminal · anywhere, after the setup sequence**

```bash
frappe services start
```

**Expect:** Lists `postgres`, `dns` and `proxy`, each `running`, then `collector running (127.0.0.1:4318)`. A second run lists them again.

## 02 · Create your bookshelf {#c-learn-create}

Leave the checkout first: an application is a directory of its own.

**Terminal · after machine setup, outside the caramel checkout**

```bash
cd ..
frappe new bookshelf
cd bookshelf
```

**Expect:** Prints `Created bookshelf. Installing locked dependencies…`, installs dependencies, configures the local site and applies the starter migrations, then prints `bookshelf is configured at https://bookshelf.caramel`. A second run stops with `Project destination must be empty; existing files were preserved` and changes nothing.

**Terminal · inside bookshelf**

```bash
frappe make resource Book title:string author:string
frappe migrate
```

**Expect:** Prints `Generated PATH` for each file it writes (application-owned models, changesets, actions, Blueprint views and request specs), then `Run frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.` A second `make resource Book` stops with `A resource route, helper or message group already exists` and writes nothing. `frappe migrate` applies the Book migration and prints `Applied N migrations.`, then `The database matches the declared schema.`; run again, it prints `Applied 0 migrations.` and the same second line.

## 03 · Check the book routes and open the site {#c-learn-check}

**Terminal · inside bookshelf**

```bash
frappe routes books
```

**Expect:** Lists the book routes with their contracts, such as `GET /books/:id App::Books::Show id:Int64(min=1)`.

**Terminal · inside bookshelf**

```bash
frappe dev
```

**Expect:** Builds the application, serves it at `https://bookshelf.caramel` and opens the browser when the first build is ready; `https://bookshelf.caramel/books` is the generated list of books, empty for now. The command holds the terminal until Ctrl-C: run the proof below in a second terminal, or stop it first.

Prove it

## Prove the bookshelf works {#c-learn-prove}

**Terminal · inside bookshelf, in a second terminal or after Ctrl-C**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` exits 0 and prints `✓ Type check passed` on a terminal, `frappe corretto` passes the generated request specs and ends with `Corretto: N of N workers passed`, and `frappe lint` exits 0. Corretto uses isolated test databases, so your development records stay separate.

Steps 02 and 03 and this proof are what `scripts/check frappe-project` runs against a new application on every release; step 01 is run by hand.

Ready for a domain with rules of its own? [Build a box office →](https://caramelize.dev/docs/0.16.0/box-office/index.md)

[← Current release](https://caramelize.dev/docs/0.16.0/releases/index.md) · [See where everything lives →](https://caramelize.dev/docs/0.16.0/project-map/index.md)

Caramel 0.16.0 · https://caramelize.dev/docs/0.16.0/getting-started/
