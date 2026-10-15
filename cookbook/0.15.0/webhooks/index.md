Cookbook / External integrations

# Receive a signed webhook.

Use action ingress for the exact signed bytes, a bounded body, and provider authentication before the contract binds.

Proved by scripts/check page-webhooks · Target: 0.15.0

| Contract | Value |
| --- | --- |
| Needs | A provider that signs each body with HMAC-SHA256 and sends the hex digest in one header, and a test-only `WEBHOOK_SECRET` in `.env.test` |
| You will have | A raw-body route limited to 256 KiB, an authenticator that runs before the contract binds, and a request spec for a valid, a forged, a missing and an oversized delivery |
| Status | Run end to end by `scripts/check page-webhooks` |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

## Where the change goes {#c-webhooks-files}

- `.env.test`: Test-only secret
- `config/routes.cr`: The inbox route
- `app/actions/hooks/inbox.cr`: Policy, verifier and handle
- `spec/requests/hooks_spec.cr`: Valid, forged, missing, oversized

## Declare the route’s request policy {#c-webhooks-ingress}

The application is `ledger`. Its action and its spec read the secret from `ENV["WEBHOOK_SECRET"]`, and `frappe new` already writes a comment-only `.env.test` to hold it.

1. **Create the application and give its specs the secret**

   **Terminal · after machine setup**

   ```bash
   frappe new ledger
   cd ledger
   ```

   **Expect:** Prints `Created ledger.`, then `ledger is configured at https://ledger.caramel`.

   **Terminal · inside the application**

   ```bash
   printf 'WEBHOOK_SECRET=test-webhook-secret\n' >> .env.test
   ```

   **Expect:** `frappe corretto` gives every spec worker the values of `.env.test`, so the value reaches both the action and the spec. `frappe dev` reads `.env` instead: a development secret goes there, and a real one is never committed.
2. **Route the inbox**

   **config/routes.cr · inside Caramel::Router.draw**

   ```crystal
   post "/hooks/inbox", App::Hooks::Inbox
   ```

   The action declares `ingress`, so this route reads raw bytes without a browser CSRF token. The body limit, the 401 and 413 it answers, and what `csrf: false` demands of an authenticator are the ingress rules. [Read the ingress rules →](https://caramelize.dev/docs/0.15.0/security/index.md)

## Verify before interpreting the body {#c-webhooks-signature}

This is one documented scheme: the hex HMAC-SHA256 of the exact body, in the `X-Signature` header. A provider that puts a timestamp in the signed text changes only `signed?`.

1. **Write the action**

   **app/actions/hooks/inbox.cr**

   ```crystal
   require "openssl/hmac"
   require "crypto/subtle"

   module App::Hooks
     # A signed webhook: the exact bytes, no browser CSRF, an HMAC over the body.
     struct Inbox < App::ApplicationAction
       ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?

       contract do
       end

       def handle(contract : Contract)
         event = JSON.parse(String.new(raw_body))
         Log.info { "Webhook #{event["id"]?} #{event["type"]?}" }
         Caramel::Response.new(202)
       end

       # Hex HMAC-SHA256 of the body, sent in one header. A provider that signs
       # a timestamp with the body changes only this method.
       private def signed? : Bool
         signature = request.headers["X-Signature"]? || return false
         expected = OpenSSL::HMAC.hexdigest(:sha256, ENV["WEBHOOK_SECRET"], raw_body)
         Crypto::Subtle.constant_time_compare(signature, expected)
       end
     end
   end
   ```

   1. `ingress` keeps the bytes as sent, caps them at 256 KiB, skips the browser CSRF check and names `signed?`; the contract is empty because a raw route binds only the route and the query.
   2. `signed?` returns false when the header is absent, so the router answers 401 before the contract binds.
   3. It computes the digest over `raw_body`, the original bytes, with the same secret the provider used.
   4. `Crypto::Subtle.constant_time_compare` compares the two digests without leaking where they differ.
   5. `handle` runs only after that: it parses the verified body, logs the event’s `id` and `type`, and returns an empty 202 through `Caramel::Response.new(202)`.
2. **Read the route’s policy**

   **Terminal · inside the application**

   ```bash
   frappe routes hooks
   ```

   **Expect:** Prints `POST /hooks/inbox App::Hooks::Inbox [raw, 256 KiB, csrf off, authenticate signed?]`: a raw route ends with its ingress policy in brackets.

## Send exact bodies in Corretto {#c-webhooks-tests}

Use `body:` for the signed text or bytes, and `headers:` for its media type and signature. Unlike `json:`, this preserves the input’s original whitespace and byte spelling. Choose one body mode per request.

1. **Sign the examples the way the provider does**

   **spec/requests/hooks_spec.cr · the signing helper**

   ```crystal
   require "../spec_helper"
   require "openssl/hmac"

   module HooksSpec
     CONTENT = {"Content-Type" => "application/json"}

     def self.signature(body : String) : String
       OpenSSL::HMAC.hexdigest(:sha256, ENV["WEBHOOK_SECRET"], body)
     end

     def self.headers(signature : String) : Hash(String, String)
       CONTENT.merge({"X-Signature" => signature})
     end
   end
   ```

   The helper signs with the `.env.test` secret, so a valid example and the action agree. A forged example signs a different body; a missing one sends only the media type; an oversized one is 262,145 bytes, one over the limit, with a valid signature, and still answers 413 because the limit applies before the authenticator runs.

   **spec/requests/hooks_spec.cr · the four examples**

   ```crystal
   describe "The webhook inbox" do
     it "accepts a body with a valid signature" do
       Corretto.session do |client|
         body = %({"id":"evt_1","type":"invoice.paid"})
         signed = HooksSpec.headers(HooksSpec.signature(body))
         client.post("/hooks/inbox", body: body, headers: signed).should have_status(202)
       end
     end

     it "refuses a forged signature" do
       Corretto.session do |client|
         body = %({"id":"evt_1","type":"invoice.paid"})
         forged = HooksSpec.headers(HooksSpec.signature("{}"))
         client.post("/hooks/inbox", body: body, headers: forged).should have_status(401)
       end
     end

     it "refuses a body without a signature" do
       Corretto.session do |client|
         body = %({"id":"evt_1","type":"invoice.paid"})
         client.post("/hooks/inbox", body: body, headers: HooksSpec::CONTENT).should have_status(401)
       end
     end

     it "refuses a body over 256 KiB before checking its signature" do
       Corretto.session do |client|
         body = "x" * 262_145
         signed = HooksSpec.headers(HooksSpec.signature(body))
         client.post("/hooks/inbox", body: body, headers: signed).should have_status(413)
       end
     end
   end
   ```

   **Terminal · inside the application**

   ```bash
   frappe corretto
   ```

   **Expect:** Prints `5 examples, 0 failures`, the four above and the generated home example, then `Corretto: 1 of 1 workers passed`.

Prove it

## Prove the signature check {#c-webhooks-prove}

**Terminal · inside the application**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` exits 0. `frappe corretto` answers 202 to the valid signature, 401 to the forged one and to the missing header, and 413 to the body over 256 KiB, then prints `Corretto: 1 of 1 workers passed`. `frappe lint` exits 0.

> Proved **Run end to end by a check.**
>
> `scripts/check page-webhooks` creates `ledger`, appends the secret to `.env.test`, copies these files at the steps above, reads the route and runs the proof, and the website build holds every snippet on this page to those files. The recipe stores no event, does not detect a duplicate delivery, and checks no timestamp against replay.

[← All recipes](https://caramelize.dev/cookbook/0.15.0/) · [Track the resulting background work →](https://caramelize.dev/cookbook/0.15.0/background-jobs/index.md)

Caramel 0.15.0 · https://caramelize.dev/cookbook/0.15.0/webhooks/
