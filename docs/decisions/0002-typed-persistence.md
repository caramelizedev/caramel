# Typed persistence for the first application workflow

Date: 2026-09-19

Status: implemented in the application workflow branch with compilation and PostgreSQL integration checks; independent review and generated-app acceptance remain pending.

Caramel will implement the small declared model API needed by generated CRUD over its existing `DB::Database` pool and migrations. It will continue to reuse `crystal-db` and `crystal-pg`; this is not a new database driver or a commitment to a complete ORM.

## Alternatives examined

Sources were fetched from the upstream default branches through GitHub on the date above and pinned below. This was a source/API evaluation, not a compatibility benchmark or a claim that any candidate cannot be adapted.

| Candidate | Useful capabilities | Integration cost for this slice |
| --- | --- | --- |
| Clear 0.10.0 | PostgreSQL focus, model mixins, SQL DSL, validations and migrations | Its connection pool initializes through `DB.open(uri)`. Caramel would need a pool injection adaptation alongside a wrapper for its proposed class/field API and existing migrations. Its manifest leaves several dependencies unversioned or on branches. |
| Avram 1.5.0 | Typed models and queries, operations, migrations; usable outside Lucky | A different model/query/operation API and a larger dependency set. Its manifest requires pg `~> 0.29.0`, while this repository pins 0.30.0. Its default connection path also opens through `DB.open`. Dependency resolution and connection integration need deliberate changes. |
| Jennifer 0.13.0 | Active Record conventions, mappings, validations, multiple adapters | Closest broad API family, but its adapter owns connection creation, preparation and migrations. The checked manifest's pg 0.28.0 requirement is a **development dependency**, not proof of a runtime incompatibility. Caramel would still need to integrate verified transport and pool ownership. |

Pinned source references:

- [Clear manifest](https://github.com/anykeyh/clear/blob/53c51df0056b0e1017a214eb4f5ad63b335d7edb/shard.yml) and [connection pool](https://github.com/anykeyh/clear/blob/53c51df0056b0e1017a214eb4f5ad63b335d7edb/src/clear/sql/connection_pool.cr).
- [Avram manifest](https://github.com/luckyframework/avram/blob/a620faeaa75347bd3b1fbc52674082501badec73/shard.yml), [connection](https://github.com/luckyframework/avram/blob/a620faeaa75347bd3b1fbc52674082501badec73/src/avram/connection.cr), and [model/query/operation conventions](https://luckyframework.org/guides/database/intro-to-avram-and-orms).
- [Jennifer manifest](https://github.com/imdrasil/jennifer.cr/blob/0f4e4bd58112dafc92ca0d76814001a66a50d745/shard.yml) and [base adapter](https://github.com/imdrasil/jennifer.cr/blob/0f4e4bd58112dafc92ca0d76814001a66a50d745/src/jennifer/adapter/base.cr).

## Decision and cost

The first model layer supports declared scalar fields, a nullable unsaved Int64 primary key, timestamps, presence validation, parameterized CRUD, typed equality conditions and ordering. Unknown source-level fields must fail compilation. Runtime database schema agreement still needs migrations and integration tests.

The application supplies the existing verified pool at boot; model operations must not open another connection path, resolve credentials independently, or change schema. A missing row has an explicit result, and failed validation performs no write. There is no association loading, callback framework, distributed cache, automatic schema synchronization, or arbitrary SQL builder in this task.

This choice gives us a small consistent generated API without adapting a second connection and migration lifecycle. It also makes field macros, query semantics and record-state behavior our maintenance responsibility. Keep that cost visible: reconsider an upstream integration when real applications require relations, more PostgreSQL types or transaction features beyond this deliberately small surface. Syntax preference alone is not a reason to rebuild those larger capabilities.
