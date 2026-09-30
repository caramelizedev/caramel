# Optional Crystal editor tools

Caramel pins two Crystal language servers per installation and runs them through `frappe lsp`. They use the installation's private toolchain root and pinned Crystal 1.21.1 compiler, never a global Crystal or Homebrew.

## What you get

- **crystalline 0.20.0** (built from commit `a5f6f1b`): go to definition, hover, limited completion, diagnostics on save, formatting with the pinned formatter, document symbols and signature help.
- **ameba-ls 0.2.0** (ameba 1.7.0): lint diagnostics with Fix and Ignore code actions.
- **liger** is disabled. It is dormant, has no releases, and its references are a stub.

The pins live in `tools/editor-darwin-arm64.json`.

## Install (once per Caramel installation)

```sh
frappe lsp install
```

Framework contributors build Frappé first and use the checkout's binary:

```sh
scripts/build-frappe
bin/frappe lsp install
```

- Needs network access, `git` and the Apple Command Line Tools. The first run builds crystalline from source and takes up to about 20 minutes; later runs verify the installed tools and finish in seconds.
- No Homebrew and no global installs. LLVM 15.0.7 (the pinned compiler's LLVM, from a checksummed conda-forge archive) exists only in a private, space-free build directory under `/private/tmp` during the build.
- The build uses a space-free temporary copy of Crystal's source and rebuilds `llvm_ext.o` against the pinned LLVM archive. The distribution's object enables ABI-breaking checks while this LLVM build disables them; the pinned toolchain is not modified.
- The pinned crystalline/LSP sources do not advertise `didSave` despite implementing save diagnostics. This build adds `textDocumentSync.save` to their capability before compilation (build recipe 3), so Zed sends saves and crystalline publishes errors.
- Every binary is checked by digest and must load libraries only from the toolchain root or macOS.
- The build compiles through the toolchain's `scripts/crystal` and `scripts/shards`; no additional language runtime is required.
- `frappe lsp` finds the toolchain the way every Caramel command does: `CARAMEL_TOOLCHAIN_ROOT` when set, otherwise the checkout's `.caramel-toolchain`, which `scripts/install-toolchain` writes.

## Framework contributors

The repository's `.zed/settings.json` runs `bin/frappe lsp crystalline` and `bin/frappe lsp ameba-ls`. The toolchain root comes from `CARAMEL_TOOLCHAIN_ROOT` or, failing that, `.caramel-toolchain`, so no shell setup is needed. Trust the worktree when Zed asks.

## Application projects

New projects include `.zed/settings.json` running `frappe lsp crystalline` and `frappe lsp ameba-ls`. For older projects, copy it from the framework's `templates/application/.zed/settings.json`.

Zed must find the project's matching `frappe` on its login-shell PATH; `frappe installations register` puts it in `~/.local/bin`. A one-off `PATH=… zed .` can start the servers initially but may be lost when Zed refreshes the worktree environment. `CARAMEL_TOOLCHAIN_ROOT` is optional because the installation's `.caramel-toolchain` names the toolchain. Before starting a server, `frappe lsp` checks the release pinned in `shard.lock`, as `frappe dev` does.

## Multiple Caramel versions

- Each Caramel installation pins its own tools.
- Installations sharing a toolchain root keep versions side by side: `editor/ameba-ls/<version>` and `editor/crystalline/<version>-<fingerprint>`. The fingerprint covers the source commit, Crystal version, LLVM artifact and build recipe, so a changed build input never reuses an old binary.
- Different Crystal pins need separate toolchain roots; `scripts/install-toolchain` enforces this.
- A project is served by the installation whose `frappe` Zed finds. `frappe lsp` runs under the release the project pins in `shard.lock`, like every project command.
- crystalline navigates into the project's Caramel dependency in `lib/caramel`; for an unreleased checkout that is a symlink to the checkout itself.

## Verify

- `scripts/check editor-tools` (framework checkout) exercises both servers over LSP for the framework and for a generated project.
- `tail -f ~/Library/Logs/Zed/Zed.log` shows `starting language server process … args: ["lsp", "crystalline"]`.
- In Zed, `dev: open language server logs` shows the server's `frappe lsp:` startup line with the binary, toolchain root and its source.

## Troubleshooting

- `frappe lsp: no Caramel toolchain is configured`: run `scripts/install-toolchain` in the Caramel checkout.
- `frappe lsp: toolchain root …` (ownership, symlink or privacy): the root must be an owned, private (0700) directory; fix it or point to the right root.
- `frappe lsp: <root> is not a completed Caramel toolchain`: rerun `scripts/install-toolchain` to finish it.
- `frappe lsp: <root> does not provide Crystal <version>`: this installation needs a toolchain root with its Crystal pin.
- `frappe lsp: <name> <version> is not installed in <root>`: run `frappe lsp install` for this installation.
- `frappe lsp: <binary> failed verification`: remove the named directory and run `frappe lsp install`.
- `frappe lsp: another editor tools installation is running`: wait for it to finish.
- `frappe lsp: checksum mismatch` or `download failed`: nothing was installed; retry on a working network.
- `frappe lsp: … loaded a library outside Caramel or macOS`: the binary was not published; report it.
- `frappe lsp: crystalline build directory preserved for inspection`: the build output above names the failure; remove the directory afterwards.
- `This project uses Caramel X, not Y; use its matching Caramel installation`: install that release with `frappe installations install X`, or register its checkout.
- Zed `failed to spawn command` for `bin/frappe`: run `scripts/build-frappe`. For `frappe`: the matching binary is absent from Zed's login-shell PATH. A one-off `PATH=… zed .` may work initially but not survive a worktree-environment refresh.
- Zed `Please install crystalline manually and make sure it is on $PATH`: the project settings were not applied (untrusted worktree or missing `.zed/settings.json`).
- Zed `Waiting for worktree … to be trusted`: trust the worktree.
- After installing, run `editor: restart language server`.
- ameba-ls intentionally disables `Layout/TrailingWhitespace` (and `Layout/TrailingBlankLines` and `Lint/Formatting`) while editing. Try `pp! 1` to verify `Lint/DebugCalls` diagnostics instead.
- Syntax diagnostics in the framework's `templates/**` are expected: those files contain generator placeholders.
- crystalline compiles the project in memory and can use several hundred MB to a few GB of RAM on large projects.
- Format on save uses crystalline, which formats with the pinned Crystal formatter.

## Other editors

Configure a stdio language server that runs `frappe lsp crystalline` or `frappe lsp ameba-ls` (framework checkout: `bin/frappe lsp …`) with the project or framework directory as its working directory.

## Removal

- All editor tools in a root: `rm -rf "<toolchain root>/editor"`, where the root is the first line of the checkout's `.caramel-toolchain`.
- One version: delete its `editor/ameba-ls/<version>` or `editor/crystalline/<version>-<fingerprint>` directory.

After deleting tools, launches report "not installed". Nothing else changes.
