#!/bin/sh
# Build the pinned node-addon-require-builtin for one Apple SDK.
#
#   build-require-builtin.sh iphoneos|macosx OUTPUT_NODE NODE_HEADERS_DIR
#
# The harness calls this addon while preparing the profile (`dsh-app-boot` asks it
# for Node's internal module loaders), so an engine without a working binding
# cannot boot at all: the server never listens and the app shows "连不上".
#
# Upstream ships an optional platform package with a prebuilt binary for desktop
# macOS, and `pnpm deploy` carries it until prepare-engine's platform pruning runs.
# The device needs the same sources compiled against the iPhoneOS SDK; the smoke
# test needs them compiled for the host, because the cached engine carries the iOS
# binary at that path.
#
# The define set is the one binding.gyp produces for the napi backend and the
# require-builtin product: sources/conditions -> NARB_BACKEND=1, NARB_PRODUCT=1,
# std=c++17, no exceptions, hidden visibility. The addon resolves Node's symbols
# at load (`-undefined dynamic_lookup`), like flock; it is never linked to a
# second copy of Node.
set -eu

SDK=${1:?usage: build-require-builtin.sh iphoneos|macosx OUTPUT_NODE NODE_HEADERS_DIR}
OUT=${2:?missing output path}
HEADERS=${3:?missing Node headers directory}
case "$SDK" in
  iphoneos | macosx) ;;
  *) printf 'build-require-builtin: unknown SDK %s\n' "$SDK" >&2; exit 1 ;;
esac
[ -f "$HEADERS/node_api.h" ] || {
  printf 'build-require-builtin: %s has no node_api.h\n' "$HEADERS" >&2
  exit 1
}
MIN_IOS=${DPSK_IOS_MIN:-16.0}

COMMIT=a58d3599a2e551d7d706d1ff796c9fd4bbaff63c
URL="https://codeload.github.com/deepseek-ai/dsh-node-addon-require-builtin/tar.gz/$COMMIT"
SHA256=286616f15e4f12013988e45ad27a69b4968a9f059c8bd351e412505230577948
API_VERSION=8.9.2

CACHE=${DSH_IOS_ENGINE_WORK:-$HOME/Library/Caches/dsh-ios-engine}
SRC="$CACHE/require-builtin-$COMMIT"
API="$CACHE/node-addon-api-$API_VERSION"
mkdir -p "$CACHE"

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ ! -f "$SRC/.verified" ]; then
  printf 'build-require-builtin: fetching %s\n' "$URL" >&2
  tmp="$CACHE/require-builtin-$COMMIT.tar.gz.partial"
  curl -fsSL --retry 3 -o "$tmp" "$URL"
  [ "$(digest "$tmp")" = "$SHA256" ] || {
    printf 'build-require-builtin: checksum mismatch for %s\n' "$URL" >&2
    exit 1
  }
  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar xzf "$tmp" -C "$SRC" --strip-components=1
  mv "$tmp" "$CACHE/require-builtin-$COMMIT.tar.gz"
  : > "$SRC/.verified"
fi
[ -f "$SRC/packages/native/binding.gyp" ] || {
  printf 'build-require-builtin: the pinned source has no packages/native/binding.gyp\n' >&2
  exit 1
}

if [ ! -f "$API/napi.h" ]; then
  printf 'build-require-builtin: fetching node-addon-api %s\n' "$API_VERSION" >&2
  (cd "$CACHE" && npm pack --silent "node-addon-api@$API_VERSION" >/dev/null)
  rm -rf "$API"
  mkdir -p "$API"
  tar xzf "$CACHE/node-addon-api-$API_VERSION.tgz" -C "$API" --strip-components=1
  rm -f "$CACHE/node-addon-api-$API_VERSION.tgz"
fi
[ -f "$API/napi.h" ] || {
  printf 'build-require-builtin: node-addon-api headers are missing\n' >&2
  exit 1
}

SOURCES="$CACHE/sources-$COMMIT.txt"
if [ ! -f "$SOURCES" ]; then
  python3 - "$SRC/packages/native/binding.gyp" > "$SOURCES" <<'PY'
import json
import os
import sys

gyp = json.load(open(sys.argv[1]))
target = None
for candidate in gyp["targets"]:
    if candidate.get("target_name") == "require_builtin":
        target = candidate
        break
if target is None:
    sys.exit("binding.gyp has no require_builtin target")
# napi backend: the condition's second branch adds the four runtime compat units.
extra = []
for condition in target.get("conditions", []):
    if condition and condition[0] == "narb_backend=='nodeabi'":
        extra = condition[2]["sources"]
for name in target.get("sources", []) + extra:
    print(os.path.join("packages/native", name))
PY
fi
[ -s "$SOURCES" ] || {
  printf 'build-require-builtin: could not read the source list\n' >&2
  exit 1
}

CXX=$(xcrun --sdk "$SDK" --find clang++)
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
[ -n "$CXX" ] && [ -n "$SYSROOT" ] || {
  printf 'build-require-builtin: xcrun could not find %s\n' "$SDK" >&2
  exit 1
}

target_flags=""
[ "$SDK" = iphoneos ] && target_flags="-target arm64-apple-ios$MIN_IOS"

# shellcheck disable=SC2046
"$CXX" $target_flags -isysroot "$SYSROOT" \
  -O2 -g0 -fPIC -fvisibility=hidden -fno-exceptions -pthread -std=c++17 \
  -DNAPI_VERSION=9 -DNARB_BACKEND=1 -DNARB_PRODUCT=1 \
  -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS -DNODE_GYP_MODULE_NAME=require_builtin \
  -I "$API" -I "$HEADERS" \
  -I "$SRC/packages/native" -I "$SRC/packages/native/src" \
  $(sed "s#^#$SRC/#" "$SOURCES") \
  -bundle -undefined dynamic_lookup \
  -o "$OUT"

# dyld maps executable code only when it carries a signature of its own; the
# re-sign tool that seals the .ipa later re-seals this file too.
codesign --force --sign - "$OUT"
lipo -info "$OUT" 2>/dev/null || file "$OUT" 2>/dev/null || true
printf 'build-require-builtin: %s\n' "$OUT"