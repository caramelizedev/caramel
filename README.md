# Caramel

Caramel is an early Crystal framework and local development environment for complete browser applications, inspired by Laravel's integrated developer experience.

The intended workflow combines PostgreSQL, server-rendered HTML with bundled htmx 4, optional one-command authentication, and named local HTTPS projects managed by Latte. Frappé is the developer CLI.

## Current state

The first toolchain feasibility milestone has runnable research scripts and recorded results. The application framework, Frappé, and Latte are not implemented yet. Mise is accepted for prototype tooling; consumer installation still needs clean-machine validation.

- [Developer experience design](docs/superpowers/specs/2026-09-19-caramel-developer-experience-design.md)
- [Toolchain decision and remaining gates](docs/decisions/0001-managed-toolchain-provider.md)
- [Installation findings](docs/research/toolchain-installation.md)
- [Reproduce the toolchain experiment](experiments/toolchain/README.md)

The next milestone is a Bookshelf application that proves the Crystal, PostgreSQL, rendering, and form workflow together.
