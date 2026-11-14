# ADR 0033: SweetTalk answers refusals with 422, binds its values and ids as contract fields, and keeps every context per tenant unless it says central

Date: 2026-10-11

Status: accepted.

## Context

SweetTalk meets the framework in three places. On the web, a domain rule that says no is an answer, yet an unrescued refusal would be a 500 with an error report. Under tenancy, SugarORM and Cold Brew follow the bound tenant once a schema declares it ([ADR 0025](../0025-tenancy.md)); what remains is which rows belong to a tenant and which combinations would leak. For ids, core offers UUIDv7 or Int64 keys ([ADR 0007](../0007-sugarorm.md)), and a domain needs one answer.

## Decision

1. **Requiring SweetTalk redefines the action's answer hook.** Core answers a valid contract through a hook whose body only yields ([ADR 0003](../0003-routing-and-ingress.md)). Core never names SweetTalk.
2. **A refusal the action does not rescue answers 422, the way a failed contract does.** Its message goes under the field the refusal names when the contract has it, and form-wide otherwise.
3. **A missing aggregate answers 404, a programming error stays a 500, and neither a refusal nor a missing aggregate is reported as an error.**
4. **Refusal messages are the domain's English.**
5. **SweetTalk's values and ids are contract field values.** They include core's field-value protocol, and a value's refusal is the field's error. A value with parts is not one.
6. **The domain names its tenant.** Under tenancy, a domain that does not name the tenant model does not compile.
7. **Every context is tenanted unless it says it is central.** A tenanted context's rows, locks and keys belong to the tenant; a central context's rows are shared by every tenant.
8. **Jobs and channels follow the tenant.** A handler runs in the tenant its event was emitted in, and a deadline in the tenant that armed it.
9. **References point from a tenant to shared data, not back.** A central context may not refer to a tenanted aggregate or schema.
10. **Shared events do not drive a tenant's rows.** A tenanted context that follows a central context's event does not compile. A central context may follow a tenanted context's events, and its handler runs in the event's tenant.
11. **The tenant's column is named after the tenant model and reserved.**
12. **A channel name that does not fit PostgreSQL with the tenant's prefix does not compile.**
13. **A domain's ids follow its tenant's key type, and are UUIDv7 without a tenant.** A domain opts into Int64 ids explicitly, and one whose ids differ from its tenant's key does not compile. A UUID id exists when its aggregate or entity is built.
14. **The tables whose order or counter is the point stay bigint, whatever the domain's ids are.**
15. **Plugging tenancy into existing data follows the framework's steps.** SweetTalk adds no migration generator of its own.

## Reasons

- A refusal is the domain's answer to a valid request, so it is answered like an invalid one, without an error report that would page someone. A boundary violation is a bug, so it stays a 500.
- Redefining the hook keeps the mapping out of every program that does not require SweetTalk.
- The domain does not know the contract, so the field is checked when the refusal is answered.
- Binding a value in the contract gives its refusal the field's key, which a form shows beside its input. A route parameter typed as one aggregate's id keeps another aggregate's id out.
- Rejected: answering refusals in the application's failure handler. It knows the request, not the action, so it can neither re-render the action's form nor use its layout.
- Rejected: a module each action includes, or a rescue in each action. One forgotten action answers 500 again.
- Rejected: a SweetTalk branch in the contract macro. Core would name SweetTalk, and no other type could bind.
- Rejected: 409 for a refusal. Caramel answers errors found after the contract with 422; one status keeps a client's handling to one shape.
- Deferred: refusal messages translated by the internationalization opt-in ([ADR 0024](../0024-internationalization.md)).
- Tenancy by default fails closed: a context left unmarked hides its rows from other tenants. Rejected: an opt-in flag per context, since one forgotten flag shares a context's rows between tenants.
- A bounded context is the unit of language and ownership, so the context decides. Rejected: central per aggregate, since one context's invariants would span tenants.
- A generated application requires its models before its routes, so a tenant model read from the routes is not yet known when a schema expands, and the domain would compile untenanted. Rejected: requiring the domain after the routes, since any other order compiles untenanted.
- A central row that names tenanted rows shows their ids to every tenant. A central event carries no tenant, so a tenanted handler would fail or write into whichever tenant the central command ran in.
- A refusal can be lifted later without breaking a program; one added after a release would break programs.
- A column named after the model matches the application's own tenanted tables, so SQL, the schema differ and the plug-in steps read the same.
- Rejected: hashed channel names. Live pages and renames rely on readable channels.
- Rejected: a generator for the plug-in migrations. It would cover only a one-tenant backfill.
- Deferred: a central event delivered to every tenant.
- An id the application holds before the insert lets aggregates compare and hash before they are saved.
- Ids follow the tenant because an event keeps the tenant's id where its aggregate ids go. A mismatch is refused at compile time rather than at the first write.
- The event log's id is the rebuild cursor, read in order, and projection and process rows are named by their key, never their id.
- Rejected: switching existing domains to UUID silently. The schema differ halts on the changed key, so no table is rewritten by accident.
