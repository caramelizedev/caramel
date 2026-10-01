#!/bin/bash
# Readies a Claude Code on the web session, which runs on Linux, to format,
# lint and run the specs that do not need macOS: the pinned Crystal, this
# checkout's shards and bin/frappe-lint. On a Mac, use
# scripts/install-toolchain instead (CONTRIBUTING.md).
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || exit 0

# A hook's standard output joins the session's context; progress does not.
exec >&2

# The Linux build of the compiler ADR 0001 pins. Moving the pin moves both
# lines: the digest is the archive's SHA-256.
VERSION=1.21.1
SHA256=08b5779df8cf280c4a799599862bbe4d42103ba082aa73429562713c8a9f3b43

CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/caramel
CRYSTAL=$CACHE/crystal-$VERSION-1
ROOT=${CLAUDE_PROJECT_DIR:-$(pwd)}

# Headers and the C compiler/archive tools Lexbor's postinstall uses.
# Most images already have them.
missing=""
for package in build-essential libpcre2-dev libssl-dev libyaml-dev zlib1g-dev; do
  dpkg -s "$package" >/dev/null 2>&1 || missing="$missing $package"
done
if [ -n "$missing" ]; then
  apt-get update -qq
  apt-get install -y -qq $missing
fi

# Verified, then moved into place whole, so a failed download never leaves
# a partial compiler behind.
if [ ! -x "$CRYSTAL/bin/crystal" ]; then
  mkdir -p "$CACHE"
  staging=$(mktemp -d "$CACHE/staging.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  release=https://github.com/crystal-lang/crystal/releases/download/$VERSION
  curl -fsSL -o "$staging/crystal.tar.gz" \
    "$release/crystal-$VERSION-1-linux-x86_64.tar.gz"
  echo "$SHA256  $staging/crystal.tar.gz" | sha256sum --check --quiet
  tar xzf "$staging/crystal.tar.gz" -C "$staging"
  rm -rf "$CRYSTAL"
  mv "$staging/crystal-$VERSION-1" "$CRYSTAL"
fi
export PATH="$CRYSTAL/bin:$PATH"
echo "export PATH=\"$CRYSTAL/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE:-/dev/null}"

# Specs and checks written for macOS keep private files under /private/tmp.
[ -e /private/tmp ] || { mkdir -p /private && ln -s /tmp /private/tmp; } || true

cd "$ROOT"
# Only a missing or stale lib/ needs the network.
shards check >/dev/null 2>&1 || shards install --frozen

# The linter is rebuilt when it is missing or its sources changed.
stale=$(find src/frappe_lint.cr src/frappe/lint shard.lock -newer bin/frappe-lint \
  2>/dev/null || echo missing)
if [ ! -x bin/frappe-lint ] || [ -n "$stale" ]; then
  mkdir -p bin
  crystal build src/frappe_lint.cr -o bin/frappe-lint
fi
