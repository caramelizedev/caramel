# Caramel DNS probe

Probe date: 2026-09-19 (America/New_York)

## Artifact verification

The host is Darwin `arm64` (`uname -m`), and `/usr/bin/dig` is BIND 9.10.6.
GitHub's official `releases/latest` API returned `v1.14.7`, pointing to
https://github.com/coredns/coredns/releases/tag/v1.14.7 and published at
`2026-08-19T01:39:14Z`.

Downloaded from official release URLs:

- Asset: https://github.com/coredns/coredns/releases/download/v1.14.7/coredns_1.14.7_darwin_arm64.tgz
- Published checksum: https://github.com/coredns/coredns/releases/download/v1.14.7/coredns_1.14.7_darwin_arm64.tgz.sha256
- Published SHA256 and local `shasum -a 256` result: `0005d154d49c73a88b2c56f429f35106e46c4ca37ee6de4e4d482d7de5c4b8ba`
- Tarball size: `21406344` bytes

The extracted binary reports `CoreDNS-1.14.7`, `darwin/arm64`, Go `1.26.6`,
revision `427fc80`. `file` reports Mach-O 64-bit arm64. `otool -L` reports
only `/usr/lib/libSystem.B.dylib`, `/usr/lib/libresolv.9.dylib`,
`CoreFoundation.framework`, and `Security.framework`; there is no external
runtime linkage. `codesign -dv --verbose=4` reports an ad-hoc linker signature
with no Team ID. The tarball contains only the binary, so a redistributable
bundle should carry the notice separately.
`./coredns -plugins` includes the required native `bind`, `hosts`, `file`, and
`template` plugins.

The official tagged source license was fetched from
https://raw.githubusercontent.com/coredns/coredns/v1.14.7/LICENSE. It is
Apache License 2.0 (local SHA256
`f0530760b1e2ffcf23df322db638ee06d06fc07fead0ed3ddd710f2e224698a9`).

## Proven CoreDNS configuration

`Corefile` binds only to loopback port `15353`:

```corefile
caramel:15353 {
    bind 127.0.0.1
    hosts <owned-dns-state>/hosts.live {
        reload 1s
        fallthrough
    }
    file <owned-dns-state>/caramel.zone caramel
}

.:15353 {
    bind 127.0.0.1
    template ANY ANY {
        rcode REFUSED
    }
}
```

`hosts.live` registers `bookshelf.caramel` and `second.caramel` at
`127.0.0.1`. The `file` plugin is an official CoreDNS fallback for the
authoritative `caramel.` zone: with `hosts` fallthrough it supplies the SOA
and NXDOMAIN for names absent from the hosts file. The root template returns
REFUSED for unrelated names, and there is no forwarding plugin.

## Query results

All rows were queried directly with `/usr/bin/dig @127.0.0.1 -p 15353`, once
over UDP and once with `+tcp`:

| Query | UDP | TCP | Evidence |
| --- | --- | --- | --- |
| `bookshelf.caramel A` | NOERROR, AA, A `127.0.0.1` | same | hosts entry |
| `second.caramel A` | NOERROR, AA, A `127.0.0.1` | same | hosts entry |
| `missing.caramel A` | NXDOMAIN, AA, SOA | same | file-zone fallback |
| `example.com A` | REFUSED, AA, no answer | same | root template; no forward |
| `bookshelf.caramel AAAA` | NOERROR, AA, zero answers (NODATA) | same | IPv4-only hosts entry |

For live reload, `third.caramel` first returned NXDOMAIN. After adding
`127.0.0.1 third.caramel` to `hosts.live` and waiting two seconds, it returned
NOERROR with A `127.0.0.1`; its AAAA query returned NOERROR with zero answers.
The CoreDNS process was then stopped and the listener was confirmed absent.

The task wording supplied “bookshelf.caramel & second project” without a
literal second hostname. This probe uses `second.caramel`; replace that one
hosts-file line with the real project slug when known. The runtime worktree's
current plan also does not name the second reference site; `neighbor.caramel`
appears in an existing negative Origin test, so it was not treated as the
registration name.

## macOS scoped resolver note

`man 5 resolver` confirms that a resolver file in `/etc/resolver` is selected
by its filename as the domain, and supports both `nameserver` and `port`.
The unmodified, hypothetical scoped file for this probe would be:

```text
nameserver 127.0.0.1
port 15353
```

No `/etc/resolver` file, `/etc/resolv.conf`, system daemon, trust store, or
other system configuration was changed.
