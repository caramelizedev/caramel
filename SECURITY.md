# Security policy

## Reporting a vulnerability

Report a vulnerability privately, not in a public issue:
[open a private report](https://github.com/caramelizedev/caramel/security/advisories/new)
on GitHub. Say what is affected, how to reproduce it and what an attacker gains.

You get an acknowledgement within seven days. The fix and its release are agreed with you
in the report, and you are credited in the advisory unless you ask not to be.

## Supported versions

During 0.x only the newest release gets security fixes; support windows are published
at 1.0 ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). A fix ships in a
release with a GitHub security advisory that names the affected versions, and
`CHANGELOG.md` lists it.

## Scope

In scope: Caramel core, SugarORM, Cold Brew, Crema, Corretto, the Frappé CLI, Latte and
this repository's installers and release scripts. A vulnerability in a dependency goes
to that project; report it here too when Caramel's use of it is what makes it exploitable.
