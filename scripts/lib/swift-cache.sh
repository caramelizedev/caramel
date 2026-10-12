# The Swift module cache for the build scripts; source it after `set -eu`.
#
# Sets CACHE_ROOT to CARAMEL_LATTE_SWIFT_CACHE, or to a directory in
# /private/tmp named for this user. The compiler trusts what it finds there,
# and one of the programs built from it runs under sudo, so the directory must
# be a real directory that this user owns and no one else can read or write.
CACHE_USER=$(id -u)
CACHE_ROOT=${CARAMEL_LATTE_SWIFT_CACHE:-/private/tmp/caramel-latte-swift-module-cache-$CACHE_USER}
[ -d "$CACHE_ROOT" ] || mkdir -p -m 700 "$CACHE_ROOT" 2>/dev/null || true
if [ ! -d "$CACHE_ROOT" ] || [ -L "$CACHE_ROOT" ] ||
    [ "$(/usr/bin/stat -f %u "$CACHE_ROOT")" != "$CACHE_USER" ] ||
    [ $(( 0$(/usr/bin/stat -f %Lp "$CACHE_ROOT") & 077 )) -ne 0 ]; then
    echo "Swift module cache $CACHE_ROOT must be a directory you own that no one else can use" >&2
    exit 1
fi
