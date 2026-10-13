Cookbook / External integrations

# Receive a signed webhook.

Use action ingress for the exact signed bytes, a bounded body, and provider authentication before the contract binds.

Draft recipe · Target: 0.14.0 · Not yet recipe-tested

## Declare the route’s request policy {#c-hook-ingress}

An action can receive raw bytes without a browser CSRF token through a supported API. Put the ingress declaration beside its contract, and implement the named authenticator.

**app/actions/hooks/inbox.cr · action declaration excerpt**

```crystal
ingress body: :raw,
  limit: 256.kilobytes,
  csrf: false,
  authenticate: :signed?
```

Raw ingress exposes `raw_body : Bytes` unchanged, for any content type. The contract binds route and query fields only. The limit can be 1 byte through 64 MiB; an oversized body returns 413. A false authenticator returns 401 before contract validation or `handle`.

## Verify before interpreting the body {#c-hook-signature}

Implement `private def signed? : Bool` using your provider’s documented signature format. Verify the original bytes with a constant-time comparison, enforce the provider’s timestamp or replay policy, then parse the verified body in `handle`. Store and deduplicate the provider’s stable event ID before enqueueing delivery work.

**Inside handle · after authentication**

```crystal
event = JSON.parse(String.new(raw_body))
```

The verifier must use a credential such as a signature or bearer token. Cookie authentication cannot replace CSRF: sessions on a CSRF-off route are empty and never saved. Disabling CSRF without naming an authenticator is a compile error. A subtype that replaces an inherited ingress must name its authenticator again.

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

> **Choose the provider before completing the recipe**
>
> Raw bodies and authenticated ingress are implemented. A provider-specific signing fixture, verifier, event store, and duplicate-delivery test are still required before this draft is a complete webhook recipe.

[← All recipes](https://caramelize.dev/cookbook/0.14.0/) · [Track the resulting background work →](https://caramelize.dev/cookbook/0.14.0/background-jobs/index.md)

Caramel 0.14.0 · https://caramelize.dev/cookbook/0.14.0/webhooks/
