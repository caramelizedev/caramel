# ADR 0013: Frappé is the CLI: one command table, stateless commands, and diagnostics for humans and agents

Date: 2026-09-27

Status: accepted.

## Context

The CLI serves humans and agents. Both need a fast loop that verifies a change, and each needs errors in a form it can act on. Crystal cannot run an application without building it natively. The CLI also needs Latte's daemon for service and database side effects.

## Decision

1. **The binary is `frappe`.** `caramel` names the framework shard that applications depend on. The commands are in `site#c-commands-frappe`.
2. **One command table states the command line.** Help, completion, argument validation, dispatch to the pinned release and the manifest an agent reads are all generated from it. Each command carries its own examples, and a spec fails when an example does not parse as its command.
3. **Every command is a one-shot process with no session state.** Latte's daemon is a service supervisor ([ADR 0012](0012-latte.md)), not an agent protocol. Frappé calls it only for service and database side effects.
4. **The verification loop is a type check without code generation.** `frappe check` runs the compiler over the application's main target and stops before code generation. It parses the compiler's real output and classifies each error under a small set of codes.
5. **Output follows where standard output goes.** On a terminal, a diagnostic is drawn for a human: the source line, a caret, the message and the remedy. Piped, it is MRDP, a line-oriented format an agent parses (`site#c-agents-diagnose`). A flag forces either mode, and usage errors and refusals from every command use the same format.
6. **A diagnostic carries its repair as a patch where the repair is mechanical.** The patch names the text to insert and the position. Where the compiler's own suggestion names the wrong thing, the diagnostic leaves it out.
7. **Whatever runs the application is a native build.** Serving, listing routes, migrating, seeding and running specs all use a compiled binary. Crystal's interpreter serves none of them. The type check remains the agent's loop.
8. **Commands share the development build.** A command reuses the build `frappe dev` or an earlier command made when its inputs are unchanged, and builds only when none matches. One lock serializes all builds of an application.
9. **A command may ask the compiled application for its answer.** Such a command is a row of the same table. Frappé runs one of the binary's own commands and prints or renders what it returns. The binary's command is built in, or registered by a library ([ADR 0027](0027-crema.md)).
10. **`frappe expand` prints the plain Crystal that a macro call expands to.** The compiler never expands a call written inside another macro's block by itself. Frappé then expands the innermost enclosing call that does expand.
11. **`frappe words` prints a vocabulary from the macros that define it.** Frappé reads each macro's parameters and the tags in its doc comment with Crystal's parser. No word is listed anywhere apart from its macro, and the checks fail when the macros, their tags and the guide disagree. The vocabulary is that of [ADR 0030](sweettalk/0030-scope-and-modules.md).
12. **A shard adds commands to the one table, under its own name.** A shard the application depends on declares its commands in a manifest at its root (`site#c-commands-shards`), and Frappé adds them to the table, where help, validation, dispatch and the agent's manifest read them as they read Frappé's own. A contributed command is always written `shard:command`, with the shard's whole name and no shorter form, and it runs as a command of the compiled application. The manifest names its format, and Frappé refuses a format newer than the one it reads. A manifest that Frappé refuses takes away that shard's commands and no other command. In the application a command name is registered once, and a second registration is an error.

## Reasons

- Naming the CLI after its product avoids renaming a shipped binary that every script and template already uses.
- A single table cannot drift from help, validation or the manifest. An agent that reads the manifest gets exactly what the parser accepts.
- A patch that applies mechanically turns a compile error into a one-step repair for an agent.
- Rejected: Crystal's interpreter for running the application. The official macOS build is compiled without it, and where present it starts more slowly than a warm build and fails under a request loop ([measurements](https://github.com/caramelizedev/caramel-notes/blob/main/research/local-performance.md#follow-up-compiler-side-options-2026-10-02)).
- One lock for all of an application's builds means no two builds write the compiler's cache at once.
- A vocabulary reference kept beside the macros drifts from them. Reading the macro itself leaves one place to edit and a check that fails when it is not edited.
- Rejected: a list of words in Frappé, which would be a second copy of what each macro states.
- Rejected: generating the guide's tables from the macros, because the guide teaches and the reference lists.
- A contributed command in the table gets what a built-in has: its usage errors, its help, its line in the agent's manifest and dispatch to the release the project pins. A manifest is data, so Frappé lists a shard's commands without building the application.
- No built-in command has a colon and every contributed command has one, so the two cannot collide, and a first word with a colon belongs to a project before any manifest is read.
- Rejected: a separate binary for each shard. Each would state help, usage errors, the diagnostic format and release dispatch again, and an agent would learn one more interface for every shard.
- Rejected: unprefixed names. Two shards, or a shard and a later built-in, could claim the same word, and a command would not show where it comes from.
- Rejected: aliases and shortcuts that drop the prefix. A second spelling is a second entry to keep in step in help and in the manifest, and it brings back the collisions the prefix removes.
- Rejected: a wrapper command in Frappé for each command of a library. Frappé would need a release for every change to a library's commands, and a library outside the framework could have none.
- A registration that replaced an earlier one silently would let one shard take over a command of another shard or of the framework without either noticing.
