#!/usr/bin/env bash
# Cross-build Node for iOS and stage everything the app links against.
#
# Run this on a Mac — it needs Xcode's iPhoneOS SDK, a host compiler and pnpm.
# The device has no Node and no Python, so nothing here runs on the phone; it
# runs once, on the machine that will also sign the app, and its output is what
# `app/ios/project.yml` links (Vendor/node) and serves (Engine/runtime).
#
#   tooling/ios/prepare-engine.sh            # Node + harness, both staged
#   tooling/ios/prepare-engine.sh --node-only
#   tooling/ios/prepare-engine.sh --harness-only
#
# What it produces, relative to the repository root:
#
#   app/ios/Vendor/node/include/node/   Node's public headers
#   app/ios/Vendor/node/lib/libnode.dylib   iOS arm64 shared library
#   app/ios/Engine/runtime/harness/     `pnpm deploy --prod` of @deepseek-ai/dsh
#
# Two facts to know before running it:
#
#   1. Node is built as a *shared library* (`--shared`), not libnode.a. That is
#      the path with an iOS precedent (nodejs-mobile ships it that way), and Xcode
#      signs an embedded dylib for us. The dylib's install name is rewritten to
#      `@rpath/libnode.dylib` so it loads from `DPSK.app/Frameworks/`.
#   2. Upstream Node's `configure.py` may not accept `--dest-os=ios`. The script
#      tries it, and on rejection falls back to `--dest-os=mac` with the iPhoneOS
#      sysroot forced through CC/CXX — the same trick nodejs-mobile uses. A build
#      that takes neither path is reported, not worked around silently.
#
# Set NODE_VERSION to pin a release (default: the version in `.nvmrc`, else
# 24.22.3). The harness requires node >= 24.9.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root=$(pwd -P)

engine_dir="$root/app/ios/Engine"
vendor_dir="$root/app/ios/Vendor/node"
work_dir="${NODE_BUILD_DIR:-$root/app/ios/Vendor/node/src}"
node_version="${NODE_VERSION:-24.22.3}"
ios_min="16.0"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

node_only=0
harness_only=0
for argument in "$@"; do
  case "$argument" in
    --node-only) node_only=1 ;;
    --harness-only) harness_only=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "prepare-engine: unknown argument $argument" >&2; exit 2 ;;
  esac
done

# Under Actions the job log needs a sign-in to read, while `::notice::` lines show
# on the run page itself; the trace is the only progress a reader of the run sees.
say() {
  printf '\n=== %s\n' "$1"
  [ "${GITHUB_ACTIONS:-}" = true ] && printf '::notice::%s\n' "$1"
  return 0
}
fail() {
  printf 'prepare-engine: %s\n' "$1" >&2
  [ "${GITHUB_ACTIONS:-}" = true ] && printf '::error title=engine build::%s\n' "$1"
  exit 1
}

# ── the harness: one deployed copy of the CLI the engine boots ───────────────

stage_harness() {
  say "deploying the harness"
  command -v pnpm >/dev/null || fail "pnpm is not installed (needed to deploy @deepseek-ai/dsh)"
  [ -f pnpm-lock.yaml ] || fail "run this from the repository root"

  # `deploy` copies the built package, so the artifacts have to be current.
  pnpm install --frozen-lockfile
  pnpm run build:lib:host

  rm -rf "$engine_dir/runtime/harness"
  mkdir -p "$engine_dir/runtime"
  pnpm --filter @deepseek-ai/dsh --prod deploy "$engine_dir/runtime/harness"

  # `host.mjs` imports `lib/bin.js`; without it the app boots and fails at once,
  # so the staging step refuses to leave a half-filled Engine/ behind.
  [ -f "$engine_dir/runtime/harness/lib/bin.js" ] \
    || fail "deploy produced no lib/bin.js — check that build:lib:host succeeded"
  [ -f "$engine_dir/host.mjs" ] || fail "Engine/host.mjs is missing"

  du -sh "$engine_dir/runtime/harness"
}

# ── Node: the iPhoneOS build of the runtime the app links ────────────────────

configure_node() {
  # `--with-intl=small-icu` is deliberate: the iOS SDK ships no ICU headers, so
  # `system-icu` cannot be configured against it, and `full-icu` triples the
  # engine's size. `--openssl-no-asm` avoids a per-arch assembly build we cannot
  # test here. `--without-inspector` drops a debug surface an app cannot host.
  ./configure \
    --shared \
    --openssl-no-asm \
    --with-intl=small-icu \
    --without-inspector \
    --without-npm \
    --without-corepack \
    --cross-compiling \
    --dest-cpu=arm64 \
    "$@"
}

# A cross-build of Node fails deep inside a make log, and the run page shows
# annotations only — one line each. The command that produced the first error,
# and the first errors themselves, are what a reader needs; the tail of the log
# is a thousand lines of the same mistake. Each goes up as its own annotation.
report_first_failure() {
  local log="$1" lineno command_line
  lineno=$(grep -n -m 1 'error:' "$log" | cut -d: -f1 || true)
  [ -n "$lineno" ] || return 0
  say "first failure: make.log line $lineno"
  # Nothing in an error message says which flags were in play; the compiler
  # invocation above it does. It is longer than one annotation, and the flags
  # that matter (`-std=`, `-isysroot`, the arch) sit at its end, so the head and
  # the tail both go up.
  command_line=$(awk -v stop="$lineno" \
    'NR < stop && (/\/clang/ || /\/c\+\+/ || /\/g\+\+/) { line = $0 } NR >= stop { print line; exit }' \
    "$log")
  if [ -n "$command_line" ]; then
    printf '%s\n' "$command_line" | fold -w 170 > "$log.command"
    head -n 2 "$log.command" | sed 's/^/::error title=engine command::/'
    tail -n 4 "$log.command" | sed 's/^/::error title=engine command (end)::/'
  else
    printf '::error title=engine command::%s\n' "(no compiler invocation above the first error)"
  fi
  head -n "$((lineno + 15))" "$log" | tail -n 16 \
    | grep -E 'error:|fatal error:' | head -n 6 | cut -c1-170 \
    | sed 's/^/::error title=engine error::/' || true
  return 0
}

stage_node() {
  say "building Node $node_version for iOS arm64"
  command -v xcrun >/dev/null || fail "xcrun is missing — this step needs Xcode"

  local sdk macsdk host_cc host_cxx
  sdk=$(xcrun --sdk iphoneos --show-sdk-path) || fail "no iPhoneOS SDK is installed"
  macsdk=$(xcrun --sdk macosx --show-sdk-path) || fail "no macOS SDK is installed"
  host_cc=$(xcrun --sdk macosx --find clang)
  host_cxx=$(xcrun --sdk macosx --find clang++)
  say "iPhoneOS SDK $(basename "$sdk"), macOS SDK $(basename "$macsdk")"

  mkdir -p "$work_dir"
  # The tarball unpacks to a directory whose name is not simply the version
  # (and a re-run may find an older tree there): ask the tree, never guess it.
  node_source() {
    find "$work_dir" -maxdepth 1 -type d -name 'node-*' \
      -exec test -f '{}/configure' \; -print 2>/dev/null | head -n 1
  }

  local source_dir
  source_dir=$(node_source)
  if [ -z "$source_dir" ]; then
    local tarball="$work_dir/node-v$node_version.tar.gz"
    [ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" \
      "https://nodejs.org/dist/v$node_version/node-v$node_version.tar.gz"
    tar -xzf "$tarball" -C "$work_dir"
    source_dir=$(node_source)
  fi
  [ -n "$source_dir" ] || fail "the Node tarball unpacked to no source tree in $work_dir"
  say "source tree: $(basename "$source_dir")"

  ( cd "$source_dir"

    # Two compilers, named on both sides. gyp's make generator reads
    # `CC_host`/`CC_target` (and the CXX/LINK twins) when cross-compiling, and
    # `$sdk/usr/bin/clang` is not a path an iPhoneOS SDK has — the SDK carries
    # headers and libraries, not tools. Both sides therefore use the macOS
    # clang, and only the target side names the iPhoneOS sysroot.
    #
    # The sysroot travels *inside* the target command as well as in
    # `CFLAGS_target`: Node builds its host tools (mksnapshot among them) in the
    # same tree, and a sysroot that reaches them is a `stdio.h not found` — the
    # host tools are ordinary macOS binaries. `CFLAGS_host` pins that side.
    export CC_host="$host_cc"
    export CXX_host="$host_cxx"
    export LINK_host="$host_cxx"
    export CFLAGS_host="-isysroot $macsdk"
    export CXXFLAGS_host="-isysroot $macsdk"
    export LDFLAGS_host="-isysroot $macsdk"
    # The C++ standard is per-toolset in gyp's Makefile (`CFLAGS_CC.host`), and a
    # cross build of Node 24 needs a C++20 compiler on both sides: the host tools
    # compile V8's abseil, which refuses anything older than C++17.
    export CFLAGS_C_host="-isysroot $macsdk"
    export CFLAGS_CC_host="-std=gnu++20 -isysroot $macsdk"

    local ios_flags="-target arm64-apple-ios$ios_min -isysroot $sdk"
    export CC_target="$host_cc $ios_flags"
    export CXX_target="$host_cxx $ios_flags"
    export LINK_target="$host_cxx $ios_flags"
    export CFLAGS_target="$ios_flags"
    export CXXFLAGS_target="$ios_flags"
    export LDFLAGS_target="$ios_flags"
    export CFLAGS_C_target="$ios_flags"
    export CFLAGS_CC_target="-std=gnu++20 $ios_flags"

    rm -rf out

    if ! configure_node --dest-os=ios 2>"$work_dir/configure-ios.log"; then
      say "Node's configure does not accept --dest-os=ios; retrying as a mac build against the iPhoneOS sysroot"
      cat "$work_dir/configure-ios.log" >&2
      rm -rf out
      configure_node --dest-os=mac \
        || fail "configure failed both ways — read $work_dir/configure-ios.log"
    fi

    # The snapshot generator is a host tool; everything else is the iOS target.
    if ! make -j"$jobs" V=1 CC_host="$CC_host" CXX_host="$CXX_host" LINK_host="$LINK_host" \
        2>&1 | tee "$work_dir/make.log"; then
      report_first_failure "$work_dir/make.log"
      fail "make failed — the iOS target does not compile as configured"
    fi
  )

  local dylib
  dylib=$(ls "$source_dir"/out/Release/libnode.*.dylib 2>/dev/null | head -n 1 || true)
  [ -n "$dylib" ] || fail "the build produced no libnode dylib"

  mkdir -p "$vendor_dir/lib" "$vendor_dir/include"
  cp "$dylib" "$vendor_dir/lib/libnode.dylib"
  install_name_tool -id "@rpath/libnode.dylib" "$vendor_dir/lib/libnode.dylib"
  rm -rf "$vendor_dir/include/node"
  cp -R "$source_dir/out/Release/include/node" "$vendor_dir/include/node"

  say "linking target check"
  lipo -info "$vendor_dir/lib/libnode.dylib"
  otool -l "$vendor_dir/lib/libnode.dylib" | grep -A2 LC_BUILD_VERSION | head -n 6
}

run_node=1
run_harness=1
if [ "$node_only" -eq 1 ]; then
  run_harness=0
fi
if [ "$harness_only" -eq 1 ]; then
  run_node=0
fi

if [ "$run_node" -eq 1 ]; then
  stage_node
fi
if [ "$run_harness" -eq 1 ]; then
  stage_harness
fi

say "done"
cat <<'NOTE'
Next:
  1. tooling/ios/build.sh iphoneos <output-dir>   # xcodegen + xcodebuild
  2. Sign and install the .ipa with your own toolchain.
Open the app, choose 本机引擎, and read Library/Logs/engine.log in the app
container if it does not come up. Session saving still needs an iOS build of
native/system's addon — see app/ios/Engine/README.md.
NOTE
