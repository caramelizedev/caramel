Learn / The Bookshelf path

# Start with something real.

Install Caramel 0.14.0, create a bookshelf, and check the generated feature with real application tests.

| Contract | Value |
| --- | --- |
| Needs | Apple Silicon macOS with Apple Command Line Tools |
| You will have | A `bookshelf` application with a generated Book resource, checked by request specs |
| Status | Not yet validated as a complete recipe |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

> **Before you start**
>
> The source installation targets Apple Silicon macOS. Install Apple Command Line Tools first; development dependencies use its C compiler and archiver. Caramel supplies its own pinned Crystal 1.21.1, PostgreSQL, Caddy, and CoreDNS.

## 01 · Install the release {#c-learn-setup}

Start from the release tag so new applications depend on the published Caramel shard. Add `~/.local/bin` to your shell’s PATH if it is not already there.

**Terminal · first installation**

```bash
git clone --branch v0.14.0 https://github.com/caramelizedev/caramel.git caramel
cd caramel
scripts/install-toolchain
scripts/build-release
bin/frappe installations register
frappe services start
```

**Expect:** `bin/frappe installations register` prints `Registered Caramel 0.14.0: ` and the checkout path, and `frappe` and `latte` in `~/.local/bin` then run this release. `frappe services start` lists `postgres`, `dns` and `proxy`, each `running`.

Configure the local resolver and ports once per machine.

**Terminal · one-time local HTTPS setup**

```bash
scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle && sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle
latte trust install
```

**Expect:** `prepare` builds the integration bundle as you. `apply` asks for administrator privileges and installs only a bundle that the user who ran `sudo` prepared. `latte trust install` trusts Latte’s local certificate authority in your login keychain.

The current release guide lists the supported APIs and development requirements.

[Read the current release guide →](https://caramelize.dev/docs/0.14.0/releases/index.md)

## 02 · Create your bookshelf {#c-learn-create}

**Terminal · after machine setup**

```bash
frappe new bookshelf
cd bookshelf
```

**Expect:** Prints `Created bookshelf. Installing locked dependencies…`, installs dependencies, configures the local site and applies the starter migrations, then prints `bookshelf is configured at https://bookshelf.caramel`.

**Terminal · inside bookshelf**

```bash
frappe make resource Book title:string author:string
frappe migrate
```

**Expect:** Prints `Generated PATH` for each file it writes (application-owned models, changesets, actions, Blueprint views and request specs), then `Run frappe migrate to apply the new schema. Use frappe routes to see the generated URLs.` `frappe migrate` applies the Book migration and prints `Applied N migrations.`, then `The database matches the declared schema.`

**Terminal · inside bookshelf**

```bash
frappe dev
```

**Expect:** Builds the application, serves it at `https://bookshelf.caramel` and opens the browser when the first build is ready. Ctrl-C stops it.

## 03 · Check the book routes {#c-learn-check}

**Terminal · inside bookshelf**

```bash
frappe routes books
```

**Expect:** Lists the book routes with their contracts, such as `GET /books/:id App::Books::Show id:Int64(min=1)`.

Prove it

## Prove the bookshelf works {#c-learn-prove}

**Terminal · inside bookshelf**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` prints `✓ Type check passed`, `frappe corretto` passes the generated request specs and ends with `Corretto: N of N workers passed`, and `frappe lint` exits 0. Corretto uses isolated test databases, so your development records stay separate.

> Draft
>
> Run these checks in your application; this learning path is not yet validated as a complete recipe.

[← Current release](https://caramelize.dev/docs/0.14.0/releases/index.md) · [See where everything lives →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/getting-started/
