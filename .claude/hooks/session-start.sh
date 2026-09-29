#!/bin/bash
# Readies a Claude Code on the web session, which runs on Linux, to format,
# lint and run the specs that do not need macOS: Crystal 1.21.0 (the pinned
# compiler), this checkout's shards and bin/frappe-lint. On a Mac, use
# scripts/install-toolchain instead (CONTRIBUTING.md).
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || exit 0

VERSION=1.21.0
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/caramel
CRYSTAL=$CACHE/crystal-$VERSION-1
ROOT=${CLAUDE_PROJECT_DIR:-$(pwd)}

# Headers the compiler links against; most images already have them.
missing=""
for package in libpcre2-dev libssl-dev libyaml-dev zlib1g-dev; do
  dpkg -s "$package" >/dev/null 2>&1 || missing="$missing $package"
done
if [ -n "$missing" ]; then
  apt-get update -qq
  apt-get install -y -qq $missing
fi

if [ ! -x "$CRYSTAL/bin/crystal" ]; then
  mkdir -p "$CACHE"
  release=https://github.com/crystal-lang/crystal/releases/download/$VERSION
  curl -fsSL "$release/crystal-$VERSION-1-linux-x86_64.tar.gz" | tar xz -C "$CACHE"
fi
export PATH="$CRYSTAL/bin:$PATH"
echo "export PATH=\"$CRYSTAL/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE:-/dev/null}"

# Specs and checks written for macOS keep private files under /private/tmp.
[ -e /private/tmp ] || { mkdir -p /private && ln -s /tmp /private/tmp; } || true

cd "$ROOT"
shards install --frozen

# The linter is rebuilt when it is missing or its sources changed.
stale=$(find src/frappe_lint.cr src/frappe/lint shard.lock -newer bin/frappe-lint \
  2>/dev/null || echo missing)
if [ ! -x bin/frappe-lint ] || [ -n "$stale" ]; then
  mkdir -p bin
  crystal build src/frappe_lint.cr -o bin/frappe-lint
fi
