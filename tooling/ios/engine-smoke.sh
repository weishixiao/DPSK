#!/bin/sh
# Boot the packed harness on this Mac and wait for the address it prints.
#
# This covers the part of the engine that lives in JavaScript: the profile, every
# patch row and the HTTP server. It does not exercise Node-for-iOS, libnode or
# the Swift shell -- those need a device or a simulator -- but it does catch the
# class of failure that shipped a broken package: a patch row the runtime no
# longer satisfies, which makes `boot()` throw and the server never listen.
#
#   tooling/ios/engine-smoke.sh
#
# Needs app/ios/Engine prepared by prepare-engine.sh and Node 22+ on PATH.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${DPSK_ENGINE_DIR:-$ROOT/app/ios/Engine}
# `.ready` stays in the engine job's workspace and is not part of the cache the
# ipa/boot jobs restore; the deployed bin.js is what actually has to be there.
[ -f "$ENGINE/host.mjs" ] && [ -f "$ENGINE/runtime/harness/lib/bin.js" ] || {
  echo "engine-smoke: no prepared engine at $ENGINE (run tooling/ios/prepare-engine.sh)" >&2
  exit 1
}
command -v node >/dev/null || {
  echo "engine-smoke: node is not on PATH (CI uses actions/setup-node 24)" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dpsk-engine.XXXXXX")
PID=
cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK/dsh" "$WORK/workspace"
export DPSK_ENGINE_ROOT="$ENGINE"
export DSH_HOME="$WORK/dsh"
export DPSK_WORKSPACE="$WORK/workspace"
export DPSK_LOG="$WORK/engine.log"
export DPSK_PORT=0
export HOME="$WORK"
export TMPDIR="$WORK"

# The harness imports the flock addon lazily, so a boot alone does not need it.
# When the host is the same architecture as the packed one, rebuild it here so a
# session write during the smoke does not fail for a platform reason; a failure
# is a note, not a verdict.
ADDON_ROOT="$ENGINE/runtime/harness/node_modules/@deepseek-ai"
# DPSK keeps Node's headers under Vendor, not beside Engine (prepare-engine.sh
# stages them there); the boot job restores that directory with the cache.
HEADERS="$ROOT/app/ios/Vendor/node/include/node"
if [ "$(uname -s)" = Darwin ] && [ -f "$ROOT/native/system/packages/entry/src/flock.c" ] &&
   [ -d "$HEADERS" ]; then
  ARCH=$(node -p 'process.arch' 2>/dev/null || echo arm64)
  PKG="$ADDON_ROOT/node-addon-system-darwin-$ARCH"
  [ -d "$PKG" ] || cp -R "$ADDON_ROOT/node-addon-system-darwin-arm64" "$PKG" 2>/dev/null || true
  if [ -d "$PKG/bin" ]; then
    clang -bundle -undefined dynamic_lookup -DNAPI_VERSION=8 -O2 \
      -I "$HEADERS" -o "$PKG/bin/system.node" \
      "$ROOT/native/system/packages/entry/src/flock.c" ||
      echo "engine-smoke: could not build the host flock addon (continuing)" >&2
    # macOS refuses an unsigned bundle in a hardened host; the ipa's copy is
    # signed by the re-sign tool, this one only has to load here.
    codesign --force --sign - "$PKG/bin/system.node" >/dev/null 2>&1 || true
  fi
fi

# This addon is not lazy: `dsh-app-boot` loads it before the server starts, and
# the engine's copy is built for iOS. Rebuild the same pinned sources for this
# host, or the smoke can only report "No usable native binding" every time.
RB_PKG=$(find -L "$ENGINE/runtime/harness/node_modules" -maxdepth 5 -type d \
  -name 'node-addon-require-builtin-darwin-arm64' -print 2>/dev/null | head -n 1)
RB="$RB_PKG/prebuilt/darwin-arm64-napi-v9.node"
if [ -n "$RB_PKG" ] && [ -f "$RB" ]; then
  if [ "$(node -p 'process.arch' 2>/dev/null || echo arm64)" = arm64 ]; then
    "$ROOT/tooling/ios/build-require-builtin.sh" macosx "$RB" "$HEADERS" ||
      echo "engine-smoke: could not build the host require-builtin binding (the boot will say so)" >&2
  else
    echo "engine-smoke: host is not arm64; the engine only carries the darwin-arm64 package" >&2
  fi
fi

node "$ENGINE/host.mjs" >"$WORK/stdout.log" 2>&1 &
PID=$!

URL=
i=0
while [ "$i" -lt 240 ]; do
  i=$((i + 1))
  if [ -f "$DPSK_LOG" ]; then
    grep -q 'harness failed to start' "$DPSK_LOG" 2>/dev/null && break
    URL=$(grep -Eo 'dsh web: http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+' "$DPSK_LOG" 2>/dev/null |
      tail -1 | sed 's/^dsh web: //') || true
    [ -n "$URL" ] && break
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done

fail() {
  echo "engine-smoke: $1" >&2
  echo '--- engine.log (tail) ---' >&2
  [ -f "$DPSK_LOG" ] && tail -n 80 "$DPSK_LOG" >&2 || true
  echo '--- stdout/stderr (tail) ---' >&2
  [ -f "$WORK/stdout.log" ] && tail -n 40 "$WORK/stdout.log" >&2 || true
  exit 1
}

[ -n "$URL" ] || fail "the harness never printed a ready address"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)
case "$CODE" in
  2?? | 3?? | 4??) ;;
  *) fail "GET $URL answered $CODE" ;;
esac

# A ready address is not a serving engine.
#
# A device build printed the address and stopped answering 250 ms later: the
# listener had bound, a required plugin had failed to import, `runCli()`
# unwound and the process fell off the end of `host.mjs`. Waiting for the
# address alone passes such a tree, and the app's own 300 ms poll never caught
# the port either.
#
# What decides is the port, not the log. `host.mjs` now holds the process open
# when `runCli()` returns, so a returned run can still be serving -- and a log
# line saying it returned is then a fact about the call, not about the service.
# The address has to answer after the app would have stopped looking, and the
# process has to be alive to answer at all.
sleep 3
CODE_AFTER=$(curl -s -o /dev/null -w '%{http_code}' "$URL" || true)
case "$CODE_AFTER" in
  2?? | 3?? | 4??) ;;
  *) fail "GET $URL answered $CODE at first, then $CODE_AFTER three seconds later" ;;
esac
if ! kill -0 "$PID" 2>/dev/null; then
  fail "the engine process exited within three seconds of printing a ready address"
fi

echo "engine-smoke: ready at $URL (HTTP $CODE, still serving after 3s)"
