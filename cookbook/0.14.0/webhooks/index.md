Cookbook / External integrations

# Receive a signed webhook.

Use action ingress for the exact signed bytes, a bounded body, and provider authentication before the contract binds.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

| Contract | Value |
| --- | --- |
| Needs | Your provider’s documented signature format and a test-only `WEBHOOK_SECRET` in `.env.test` |
| You will have | A raw-body route with a bounded body and an authenticator that runs before the contract binds |
| Status | Draft: the provider-specific signing fixture, verifier, event store and duplicate-delivery test are still required |
| Proved by | `frappe corretto` |

## Where the change goes {#c-hook-files}

- `app/actions/hooks/inbox.cr`: Route’s request policy
- `.env.test`: Test-only secret
- `spec/requests/`: Signed and forged examples

## Declare the route’s request policy {#c-hook-ingress}

An action can receive raw bytes without a browser CSRF token through a supported API. Put the ingress declaration beside its contract, and implement the named authenticator.

**app/actions/hooks/inbox.cr · action declaration excerpt**

```crystal
ingress body: :raw,
  limit: 256.kilobytes,
  csrf: false,
  authenticate: :signed?
```

| Setting | Meaning |
| --- | --- |
| `body: :raw` | Exposes `raw_body : Bytes` unchanged, for any content type; the contract binds route and query fields only |
| `limit:` | From 1 byte through 64 MiB |

| Condition | Outcome |
| --- | --- |
| Body over the limit | answers 413 |
| Authenticator returns false | answers 401 before contract validation or `handle` |

## Verify before interpreting the body {#c-hook-signature}

The verifier must use a credential such as a signature or bearer token.

1. Implement `private def signed? : Bool` using your provider’s documented signature format.
2. Verify the original bytes with a constant-time comparison.
3. Enforce the provider’s timestamp or replay policy.
4. Parse the verified body in `handle`.
5. Store and deduplicate the provider’s stable event ID before enqueueing delivery work.

**Inside handle · after authentication**

```crystal
event = JSON.parse(String.new(raw_body))
```

| Condition | Outcome |
| --- | --- |
| Cookie authentication on a CSRF-off route | has no session to read: it is empty and never saved |
| `csrf: false` without an authenticator | fails compilation |
| A subtype replaces an inherited ingress without naming its authenticator | fails compilation |

## Send exact bodies in Corretto {#c-hook-tests}

Use `body:` for the signed text or bytes, and `headers:` for its media type and signature. Unlike `json:`, this preserves the input’s original whitespace and byte spelling. Choose one body mode per request.

**Corretto · request excerpt with provider fixture headers**

```crystal
body = %({"event_id":"evt_1",  "amount":1})
client.post("/hooks/inbox", body: body, headers: valid_headers)
  .should have_status(202)
client.post("/hooks/inbox", body: body, headers: forged_headers)
  .should have_status(401)
```

Put a test-only `WEBHOOK_SECRET` in committed `.env.test`; development `.env` values do not reach specs. Also cover missing or stale signatures, oversized bodies, duplicate events, and retries that repeat an external call. Inspect the policy with `frappe routes hooks`.

**Terminal · inside the application**

```bash
frappe routes hooks
```

**Expect:** Lists the hooks routes; a raw route ends with its ingress policy in brackets, such as `[raw, 256 KiB, csrf off, authenticate signed?]`.

Prove it

## Prove the signature check {#c-hook-prove}

**Terminal · inside the application**

```bash
frappe corretto
```

**Passing:** The request with valid headers answers 202 and the request with forged headers answers 401. Still to cover: missing or stale signatures, oversized bodies, duplicate events, and retries that repeat an external call.

> Draft **Choose the provider before completing the recipe**
>
> Raw bodies and authenticated ingress are implemented. A provider-specific signing fixture, verifier, event store, and duplicate-delivery test are still required before this draft is a complete webhook recipe.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Track the resulting background work →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/webhooks/
