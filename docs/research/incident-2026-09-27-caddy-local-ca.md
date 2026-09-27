# Incident: Caddy installed an implicit local CA into trust stores (2026-09-27)

**Action for the machine owner:** optional cleanup, which requires your credentials, is listed at the end of this note. If macOS is showing an administrator authorization dialog that mentions certificate trust settings, choose **Cancel**.

## What happened

At 09:46 local time, `scripts/check browser` was under development. Its disposable Latte fixture (state under `/private/tmp`) served a `browser.localhost` site through Caddy. Caddy issued that site's leaf certificate from Latte's declared `caramel` CA. It also implicitly provisioned its default `local` internal CA. Latte did not declare that CA, so Caddy used its default of installing trust, and it tried to install the CA's root:

- It added the certificate `Caddy Local Authority - 2026 ECC Root` to `/Library/Keychains/System.keychain`. The SHA-256 fingerprint is `2884ED58F76BD9F97C0F4795A0828135E26D507BCCA44B19E8926306914002E2`. No administrator trust settings were applied: `security dump-trust-settings -d` does not list it.
- It added the same root as a trusted entry to the Java trust store `~/.sdkman/candidates/java/current/lib/security/cacerts`, under the alias `caddy local authority - 2026 ecc root 307657962545710695828661662839655949947`.
- It made macOS `SecurityAgent` open an administrator authorization dialog at 09:46:19. The requesting process has exited. The dialog cannot be answered on the owner's behalf, and nothing was approved.

## Containment

- The CA's private keys (`root.key` and `intermediate.key`) existed only in the fixture's `pki/authorities/local` directory. They were deleted at 09:49. Nothing can now issue a certificate that chains to that root, so both stray trust-store entries are inert.
- The keychain and Java trust store were not modified further. Changing them needs the owner's authorization.

## Root cause and fix

Latte's Caddy configuration (`src/latte/proxy.cr`) lists every registered site name in `apps.tls.certificates.automate` and declared only the `caramel` CA, with `install_trust: false`. An explicit automation policy covers those names with the internal issuer and `ca: "caramel"`.

In Caddy 2.11.4, `modules/caddytls/tls.go` lines 298–313 run while the TLS app provisions. If any `automate` name fails `certmagic.SubjectQualifiesForPublicCert`, Caddy provisions a hidden default internal automation policy, `{"module":"internal"}`. It does this even when an explicit policy already covers the name. Names under `.localhost` fail that test; `.caramel` and `.test` names pass it. The hidden policy's internal issuer has no `ca`, so it defaults to `local`, and `modules/caddypki/pki.go` `GetCA` then provisions that default CA on demand (lines 131–140). Because the configuration did not declare `local`, its `install_trust` was unset, which Caddy treats as true. When the PKI app started, its `Start` method (lines 93–100) called `installRoot` for `local`, and that tried the system keychain, NSS and Java trust stores. The hidden policy never issued anything: the `browser.localhost` leaf certificate came from the explicit `caramel` policy.

Registering the first `.localhost` site triggered this. Before this change Latte accepted only `.caramel` and `.test` suffixes, so this Caddy code path never ran.

The fix declares `local` next to `caramel` in `apps.pki.certificate_authorities`, both with `install_trust: false`. Caddy may still create the unused `local` key pair in Latte's private Caddy storage, but it never installs that root. `spec/latte/network_config_spec.cr` asserts that the generated configuration declares exactly `caramel` and `local` and enables trust installation for neither. Running `caddy validate` against a configuration with a `.localhost` site confirmed that both CAs are provisioned and no other. Validation provisions modules but never starts the PKI app, so it cannot install trust.

The contributor fixture (`scripts/checks/support/latte_fixture.cr`, used by `scripts/check browser` and `scripts/check frappe-project`) adds two guards:

- It checks trust after services start, after each upstream registration, after the browser check registers its `.localhost` site, and at teardown. The check fails if any Caddy proxy log contains `installing root certificate`, or if a PKI authority exists that the current Caddy configuration does not declare with `install_trust: false`. On failure it deletes every fixture CA private key.
- It starts the fixture's Latte daemon, and therefore Caddy, with `HOME` set to a directory inside the fixture and `JAVA_HOME` unset. NSS and Java trust-store discovery therefore cannot reach the owner's real stores. The system keychain is not reachable through the environment, so the declared-untrusted CAs remain the primary barrier. Real Latte installations keep their environment unchanged.

After the fix, guarded `scripts/check browser` runs served `browser.localhost` through Caddy. The guard passed each time, and the stores did not change: `/Library/Keychains/System.keychain` still held 4 certificates, 1 of them the stray Caddy root, and the Java `cacerts` still held 147 trusted entries.

## Optional cleanup (owner)

```sh
sudo security delete-certificate -Z 2884ED58F76BD9F97C0F4795A0828135E26D507BCCA44B19E8926306914002E2 /Library/Keychains/System.keychain
keytool -delete -alias "caddy local authority - 2026 ecc root 307657962545710695828661662839655949947" \
  -keystore ~/.sdkman/candidates/java/current/lib/security/cacerts -storepass changeit
```
