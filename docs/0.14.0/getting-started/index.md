Learn / The Bookshelf path

# Start with something real.

Install Caramel 0.14.0, create a bookshelf, and check the generated feature with real application tests.

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

Configure the local resolver and ports once per machine. The apply step installs system integration and asks for administrator privileges; `latte trust install` trusts Latte’s local certificate authority in your login keychain.

**Terminal · one-time local HTTPS setup**

```bash
scripts/install-local-integration prepare /private/tmp/caramel-integration-bundle && sudo scripts/install-local-integration apply /private/tmp/caramel-integration-bundle
latte trust install
```

The current release guide lists the supported APIs and development requirements.

[Read the current release guide →](https://caramelize.dev/docs/0.14.0/releases/index.md)

## 02 · Create your bookshelf {#c-learn-create}

**Terminal · after machine setup**

```bash
frappe new bookshelf
cd bookshelf
frappe make resource Book title:string author:string
frappe migrate
frappe dev
```

`frappe new` installs dependencies, configures the local site, and applies the starter migrations. The resource generator adds application-owned models, changesets, actions, Blueprint views, and request specs.

## 03 · Check your first feature {#c-learn-check}

**Terminal · inside bookshelf**

```bash
frappe routes books
frappe check
frappe corretto
frappe lint
```

Expect book routes, a successful type check, and passing generated request specs. Corretto uses isolated test databases; your development records remain separate. Run these checks in your application; this learning path is not yet validated as a complete recipe.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [See where everything lives →](https://caramelize.dev/docs/0.14.0/project-map/index.md)

Caramel 0.14.0 · https://caramelize.dev/docs/0.14.0/getting-started/
