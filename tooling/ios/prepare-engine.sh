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
#   2. `--dest-os=ios` is accepted by Node 24's `configure.py` (it defines
#      `V8_TARGET_OS_IOS`), and on rejection the script falls back to
#      `--dest-os=mac`. Either way gyp still emits *macOS platform* compile
#      lines — a macOS `-isysroot` on every object, no `-std=` — while also
#      building host tools in the same tree. The compilers gyp is given are
#      therefore two wrappers that pick the sysroot and the C++ standard from
#      the output path (`obj.host/` against `obj.target/`); see
#      `write_toolchain_wrapper`.
#
# Set NODE_VERSION to pin a release (default: the version in `.nvmrc`, else
# 24.22.3). The harness requires node >= 24.9.
#
# The build tree -- the unpacked Node source and its out/ -- is the expensive part
# of this script, so CI caches it and hands it back on the next run. Whether it may
# be reused is decided here, not by the cache key: the tree carries a stamp
# (`out/.dpsk-ios-tree`) recording the wrapper version and the patch set it was
# built from. A matching wrapper reuses every object; a changed patch set puts the
# pristine sources back first and lets `make` rebuild only what moved; a changed
# wrapper discards the objects. The stamp's wrapper field is a hash of the
# generated compiler wrappers, so nothing has to be bumped by hand for that;
# `tooling/ios/tree-cache-key` is what a layout or Node-version change does.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root=$(pwd -P)

engine_dir="$root/app/ios/Engine"
vendor_dir="$root/app/ios/Vendor/node"
work_dir="${NODE_BUILD_DIR:-$root/app/ios/Vendor/node/src}"
node_version="${NODE_VERSION:-24.22.3}"
ios_min="16.0"

# The build tree -- the unpacked Node source plus out/ -- is the expensive half of
# this script: a cold cross-build compiles V8 twice and runs about two hours on
# the three-core runner CI uses. It is cached and reused (see ios.yml), and these
# two values are what make reuse safe.
#
# Where the unpatched copy of every file a patch rewrites is kept, relative to the
# Node source tree. See remember_pristine.
pristine_dir=.dpsk-ios-pristine
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
  #
  # `--frozen-lockfile` is the right default: a lockfile that disagrees with the
  # manifests means the tree being built is not the tree that was tested. A device
  # build must not be blocked on such a disagreement, though -- staging the harness
  # needs working node_modules, and the lockfile this step rewrites lives only on
  # the runner -- so the mismatch is reported loudly instead of failing, and the
  # install is retried without the lockfile. The proper fix is what was done for
  # packages/reverse/: regenerate the lockfile and commit it (that is also what the
  # e2e workflow's `Install (immutable)` step requires).
  if ! pnpm install --frozen-lockfile; then
    say "pnpm-lock.yaml does not match the manifests; installing without it"
    printf 'prepare-engine: pnpm-lock.yaml has no entries for packages/reverse/* and packages/bundle/reverse;\n' >&2
    printf 'prepare-engine: regenerating it on the runner. Commit the regenerated lockfile to restore a frozen install.\n' >&2
    pnpm install --no-frozen-lockfile
  fi
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

# Node's gyp build cross-compiles through the macOS platform settings, so every
# compile line ends with `-isysroot <MacOSX.sdk>`. That is right for the host
# tools Node builds beside the target and wrong for the target itself, and the
# only thing that says which is which is the output path (`obj.host/` against
# `obj.target/`). gyp's Makefile therefore gets a wrapper as its compiler
# instead of the real one: the wrapper drops the sysroot gyp chose, names the
# right one, and pins the C++ standard gyp leaves out on this platform.
write_toolchain_wrapper() {
  local path="$1" real="$2"
  cat > "$path" <<'WRAPPER'
#!/bin/bash
# Written by tooling/ios/prepare-engine.sh; regenerated on every build.
set -eu
real="@REAL@"
host_sysroot="@HOST_SYSROOT@"
target_sysroot="@TARGET_SYSROOT@"
target_triple="@TARGET_TRIPLE@"

# `obj.target` appears in the arguments of everything that becomes part of the
# app's Node; anything else is a tool that has to run on this Mac.
kind=host
is_cxx=0
for a in "$@"; do
  case "$a" in
    */obj.target/*) kind=target ;;
  esac
  case "$a" in
    *.cc|*.cpp|*.cxx|*.mm) is_cxx=1 ;;
  esac
done

args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then
    skip=0
    continue
  fi
  case "$a" in
    -isysroot|-target|-arch|-miphoneos-version-min|-mmacosx-version-min)
      skip=1
      ;;
    -isysroot=*|-target=*|-arch=*|-mmacosx-version-min=*|-miphoneos-version-min=*|-mios-version-min=*)
      ;;
    *)
      args[${#args[@]}]="$a"
      ;;
  esac
done

prefix=()
if [ "$is_cxx" = 1 ]; then
  prefix[${#prefix[@]}]="-std=gnu++20"
fi
if [ "$kind" = host ]; then
  prefix[${#prefix[@]}]="-isysroot"
  prefix[${#prefix[@]}]="$host_sysroot"
else
  prefix[${#prefix[@]}]="-target"
  prefix[${#prefix[@]}]="$target_triple"
  prefix[${#prefix[@]}]="-isysroot"
  prefix[${#prefix[@]}]="$target_sysroot"
  # V8 reads these to decide it is on iOS, and its `platform-darwin.cc` then
  # takes the declarations from `src/base/ios-headers.h` instead of the SDK's
  # `mach/mach_vm.h`, which is a stub that refuses to compile. The symbols are
  # real: libsystem_kernel exports `mach_vm_map` and `mach_vm_remap` on iOS.
  # `--dest-os=mac` no longer defines them, so the wrapper does.
  # `V8_HAVE_TARGET_OS` is what `v8config.h` wants beside a `V8_TARGET_OS_*`:
  # without it, a target-OS macro is an error rather than a choice.
  prefix[${#prefix[@]}]="-DV8_TARGET_OS_IOS=1"
  prefix[${#prefix[@]}]="-DV8_HAVE_TARGET_OS=1"
fi

# Trailing flags, because gyp puts its own `-O3` and `-gdwarf-2` at the end of the
# command line and the last one wins.
#
# Debug info is the single largest cost in this build and the app never reads it:
# a shipped libnode.dylib is stripped by the archive step, and a 300 MB dylib of
# DWARF also slows the link and the sign step. `-g0` removes it for both sides.
#
# Host tools are different: `mksnapshot`, `torque` and the rest run once, on this
# Mac, to generate a snapshot and some C++ sources. Optimizing them at `-O3` costs
# the same as optimizing V8 itself and buys nothing at run time, so they build at
# `-O1`. The target keeps gyp's `-O3`: that code ships.
suffix=()
if [ "$kind" = host ]; then
  suffix[${#suffix[@]}]="-O1"
fi
suffix[${#suffix[@]}]="-g0"

# ccache, when the run put one on PATH (see stage_node): a rebuild that make
# decides to do -- a moved SDK, a regenerated header -- then replays cached objects
# instead of compiling for hours. It sits here rather than in the environment
# because gyp calls this script, not a compiler.
if [ -n "${DPSK_CCACHE:-}" ] && [ -x "${DPSK_CCACHE:-}" ]; then
  exec "$DPSK_CCACHE" "$real" "${prefix[@]}" ${args[@]+"${args[@]}"} "${suffix[@]}"
fi
exec "$real" "${prefix[@]}" ${args[@]+"${args[@]}"} "${suffix[@]}"
WRAPPER
  sed -i '' \
    -e "s|@REAL@|$real|g" \
    -e "s|@HOST_SYSROOT@|$macsdk|g" \
    -e "s|@TARGET_SYSROOT@|$sdk|g" \
    -e "s|@TARGET_TRIPLE@|arm64-apple-ios$ios_min|g" \
    "$path"
  chmod 755 "$path"
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

# ── what the build tree may keep, and what has to be put back ───────────────

# The patch set as one string. Every edit of any patch file changes it; that is
# the signal that a reused tree has to have its pristine copies restored before
# the current set is applied again.
patches_fingerprint() {
  local file
  for file in "$root"/tooling/ios/patches/*.patch; do
    [ -f "$file" ] || continue
    basename "$file"
    digest <"$file"
  done | digest
}

# macOS ships `shasum`, Alpine `sha256sum`; only the 64 hex characters matter.
digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    sha256sum | cut -d' ' -f1
  fi
}

# The files a patch file rewrites, as paths relative to the source tree.
patch_targets() {
  sed -n 's|^+++ b/||p' "$1" | sed 's/[[:space:]].*$//'
}

# Record the unpatched text of every file the patches are about to touch, once.
# A fresh tree stores the originals; a reused tree already has them and is left
# alone, so what is stored is always unpatchable-clean rather than whatever the
# last run left behind.
remember_pristine() {
  local source_dir="$1" file rel
  mkdir -p "$source_dir/$pristine_dir"
  {
    # `patch_ios_deps` rewrites this one with sed; it belongs to the same set.
    printf 'deps/cares/config/darwin/ares_config.h\n'
    for file in "$root"/tooling/ios/patches/*.patch; do
      [ -f "$file" ] && patch_targets "$file"
    done
  } | while IFS= read -r rel; do
    if [ -n "$rel" ] && [ -f "$source_dir/$rel" ] && [ ! -f "$source_dir/$pristine_dir/$rel" ]; then
      mkdir -p "$(dirname "$source_dir/$pristine_dir/$rel")"
      cp "$source_dir/$rel" "$source_dir/$pristine_dir/$rel"
    fi
  done || true   # `read` ends on EOF with a non-zero status; `set -e` would exit
}

# Put the pristine copies back. This is what makes a *removed* patch actually go
# away: without it the old text would stay in the tree for ever, and `make` would
# happily link objects built from it.
restore_pristine() {
  local source_dir="$1" rel
  [ -d "$source_dir/$pristine_dir" ] || return 0
  ( cd "$source_dir/$pristine_dir" && find . -type f -print ) | while IFS= read -r rel; do
    rel="${rel#./}"
    if [ -f "$source_dir/$pristine_dir/$rel" ]; then
      cp "$source_dir/$pristine_dir/$rel" "$source_dir/$rel"
      printf 'unpatched %s\n' "$rel"
    fi
  done || true
}

# make decides by mtime, and a cache round trip does not promise to keep them: one
# file that comes back newer than the object built from it costs a rebuild of
# everything below it. Measured on run 23 -- 5878 objects present, and make still
# started 2133 compile commands. So a reused tree has every file stamped with one
# fixed time; the patches then apply on top and are, by construction, newer than
# every object they affect. That is exactly the rebuild make should do, and nothing
# more.
normalize_tree_mtimes() {
  local source_dir="$1"
  # Two tiers, not one: sources at 2000, everything under out/ at 2030. Equal
  # timestamps are the subtle case -- the archive keeps nanoseconds that `touch -t`
  # zeroes, so "equal" can still compare as older and rebuild the world. Strictly
  # newer is not ambiguous.
  find "$source_dir" -path "$source_dir/out" -prune -o -type f \
    -exec touch -t 200001010000 {} + 2>/dev/null || true
  find "$source_dir/out" -type f -exec touch -t 203001010000 {} + 2>/dev/null || true
  return 0
}

# `patch` keeps the original file's mtime, so after normalize_tree_mtimes a patched
# source still looks older than the object built from it -- and make would link the
# old object. Mark the files the patch set rewrites as changed, which is what they
# are. Only a handful of files are involved, so this costs a handful of rebuilds.
mark_patched_sources_changed() {
  local source_dir="$1" file rel
  {
    printf 'deps/cares/config/darwin/ares_config.h\n'
    for file in "$root"/tooling/ios/patches/*.patch; do
      [ -f "$file" ] && patch_targets "$file"
    done
  } | while IFS= read -r rel; do
    # 2040: newer than every object (2030), so make rebuilds exactly what a patch
    # changed and nothing else.
    [ -n "$rel" ] && [ -f "$source_dir/$rel" ] && touch -t 204001010000 "$source_dir/$rel"
  done || true
  return 0
}

# A tree restored from a cache written before the wrapper path became stable names
# the old mktemp directory in every generated makefile. Point those at the current
# wrapper instead of re-running configure: configure rewrites the generated
# prerequisites, and everything downstream of them rebuilds. mtimes are preserved,
# because a newer makefile is itself a reason for make to start over.
retarget_legacy_toolchain() {
  local source_dir="$1" toolchain="$2" file
  [ -d "$source_dir/out" ] || return 0
  # Only the generated build files name the compiler; an object file must never be
  # rewritten, so the search is by name rather than by content.
  find "$source_dir/out" -type f \
      \( -name '*.mk' -o -name 'Makefile' -o -name '*.gypi' \) -print 2>/dev/null \
    | while IFS= read -r file; do
      grep -q 'dpsk-ios-toolchain\.' "$file" 2>/dev/null || continue
      case "$file" in
        *"$toolchain"/*) continue ;;
      esac
      cp -p "$file" "$file.dpsk-retarget"
      sed -i '' -E "s|[^ \"']*/dpsk-ios-toolchain\.[A-Za-z0-9]+|$toolchain|g" "$file"
      touch -r "$file.dpsk-retarget" "$file"
      rm -f "$file.dpsk-retarget"
    done || true
  return 0
}

# The tree's own description of how it was built, written inside out/ so that
# `rm -rf out` also forgets it. One line of JSON, read back with sed.
stamp_file=.dpsk-ios-tree
read_stamp() {
  sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",]*\)\"\{0,1\}.*/\1/p" "$1/out/$stamp_file" 2>/dev/null | head -n 1
}

# c-ares carries a checked-in macOS configuration (`config/darwin`) that Node
# reuses verbatim for an iOS target. Two of its macOS truths are untrue on iOS:
# the iPhoneOS SDK has no `sys/random.h`, and libSystem exports no `getentropy`.
# With both undefined c-ares reads `arc4random_buf` instead, which iOS has.
patch_ios_deps() {
  local source_dir="$1" ares_config
  ares_config="$source_dir/deps/cares/config/darwin/ares_config.h"
  [ -f "$ares_config" ] || return 0
  sed -i '' -E \
    -e 's@^#define[[:space:]]+HAVE_SYS_RANDOM_H([[:space:]].*)?$@/* #undef HAVE_SYS_RANDOM_H */@' \
    -e 's@^#define[[:space:]]+HAVE_GETENTROPY([[:space:]].*)?$@/* #undef HAVE_GETENTROPY */@' \
    "$ares_config"
  return 0
}

# Node's own sources say `__APPLE__` wherever it means macOS, and the few places
# where iOS disagrees are not worth a configure flag: they are carried as patch
# files beside this script and applied to the unpacked tree. Each patch is
# probed in both directions first, so a re-run over an already-patched tree
# (`--node-only` twice) reports that instead of failing or applying twice.
patch_ios_sources() {
  local source_dir="$1" file
  for file in "$root"/tooling/ios/patches/*.patch; do
    [ -f "$file" ] || continue
    # `-o /dev/null` is the dry run: patch writes the result there instead of
    # into the tree, so a probe touches no source file. Long options are
    # avoided — the runner's patch is BSD, whose option set is not GNU's.
    if ( cd "$source_dir" && patch -p1 -R -f -r /dev/null -o /dev/null <"$file" >/dev/null 2>&1 ); then
      say "already patched: $(basename "$file")"
    elif ( cd "$source_dir" && patch -p1 -f -r /dev/null -o /dev/null <"$file" >/dev/null 2>&1 ); then
      say "patching $(basename "$file")"
      ( cd "$source_dir" && patch -p1 -f -r /dev/null <"$file" >/dev/null ) \
        || fail "$(basename "$file") applied in a probe but failed for real"
    else
      fail "$(basename "$file") applies to neither the source tree nor a patched one — does Node $node_version still match it?"
    fi
  done
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

  # The wrappers are generated per build and live outside the source tree, so a
  # checkout is never dirtied by them. The path is stable on purpose: gyp bakes it
  # into the makefiles it generates, and a reused tree keeps those makefiles. A
  # fresh mktemp directory per run would leave every restored makefile pointing at
  # a compiler that no longer exists, and re-running configure to repair that
  # rewrites the generated prerequisites -- which is what turned a "warm" tree
  # back into a full rebuild (openssl, ICU and V8 all recompiled after
  # `configure completed successfully`). Under $work_dir, so it travels with the
  # cached tree.
  mkdir -p "$work_dir"
  local toolchain_dir="$work_dir/toolchain"
  mkdir -p "$toolchain_dir"
  write_toolchain_wrapper "$toolchain_dir/cc" "$host_cc"
  write_toolchain_wrapper "$toolchain_dir/cxx" "$host_cxx"
  # The stamp records this hash instead of a hand-bumped number: the objects are
  # valid exactly while the wrappers are byte-identical, which also covers an
  # Xcode or SDK move that changes a sysroot path.
  local wrapper_hash
  wrapper_hash=$( { digest <"$toolchain_dir/cc"; digest <"$toolchain_dir/cxx"; } | digest )

  # ccache is optional and lives inside the tree, so it is cached with it: the
  # workflow installs it, and a machine without it just compiles as before.
  DPSK_CCACHE=$(command -v ccache 2>/dev/null || true)
  export DPSK_CCACHE
  export CCACHE_DIR="$work_dir/ccache"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
  if [ -n "$DPSK_CCACHE" ]; then
    say "ccache $("$DPSK_CCACHE" --version | head -n 1 | cut -d' ' -f2) at $CCACHE_DIR"
  fi
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

    # One compiler for both toolsets: the wrapper sorts each invocation out by
    # its output path, which is the one thing gyp's Makefile gets right here.
    export CC_host="$toolchain_dir/cc"
    export CXX_host="$toolchain_dir/cxx"
    export LINK_host="$toolchain_dir/cxx"
    export CC_target="$toolchain_dir/cc"
    export CXX_target="$toolchain_dir/cxx"
    export LINK_target="$toolchain_dir/cxx"

    local patch_set reused=0
    patch_set=$(patches_fingerprint)

    # A restored tree is reused whenever it was built by this same wrapper: that
    # is the one thing whose change makes every object wrong. The patch set is
    # different -- patches rewrite a handful of files, so the tree is reused and
    # `make` rebuilds exactly what moved, which takes seconds instead of the two
    # hours a discarded tree costs. That is the whole point of the stamp.
    #
    # The two decisions are independent: a wrapper change discards the objects but
    # leaves the sources, so the patch set still has to be put back to its pristine
    # text before the current patches go on -- otherwise a *removed* patch would
    # live on in the tree and make would link objects built from it.
    if [ -f "out/$stamp_file" ]; then
      if [ "$(read_stamp "$source_dir" wrapper)" = "$wrapper_hash" ]; then
        reused=1
      else
        say "the compiler wrapper changed since this tree was built; the objects are rebuilt from scratch"
      fi
      if [ "$(read_stamp "$source_dir" patches)" != "$patch_set" ]; then
        [ -d "$source_dir/$pristine_dir" ] \
          || fail "the restored tree was built by an older script and carries no pristine sources; delete the node-tree cache (or bump tooling/ios/tree-cache-key) and build again"
        say "the patch set changed since this tree was built; restoring the pristine sources"
        restore_pristine "$source_dir"
      fi
    elif [ -d out ]; then
      # A tree restored from the caches written before this stamp existed
      # (node-tree-v1-/v2- keys) carries no record of how it was built. It was
      # built by the same wrapper this script generates today, and its
      # sources already hold the patch set of the time, so the objects are reused
      # rather than paying the two hours again -- the workflow only hands such a
      # tree over once, and the bookkeeping starts from here on. A tree for a
      # different Node version is a different matter and is discarded.
      case "$(basename "$source_dir")" in
        *"$node_version"*)
          reused=1
          say "the restored tree predates the stamp; its objects are reused as they are"
          ;;
        *)
          say "the restored tree is for another Node version; it is discarded"
          ;;
      esac
    fi

    # Only a fresh tree is guaranteed unpatched; on a reused one the copies came
    # with the tree, and re-recording would capture patched text as pristine.
    if [ "$reused" = 0 ] && [ ! -d "$source_dir/$pristine_dir" ]; then
      remember_pristine "$source_dir"
    fi
    if [ "$reused" = 1 ]; then
      # Before the patches: everything in a reused tree is one fixed time, so that
      # nothing but what a patch rewrites can look stale to make.
      normalize_tree_mtimes "$source_dir"
    fi
    patch_ios_deps "$source_dir"
    patch_ios_sources "$source_dir"
    if [ "$reused" = 1 ]; then
      # `patch` keeps the original mtime, so the files it rewrote would still look
      # older than their objects; mark them changed, which is what they are.
      mark_patched_sources_changed "$source_dir"
    fi

    if [ "$reused" = 1 ]; then
      say "reusing the build tree: $(find out -name '*.o' 2>/dev/null | wc -l | tr -d ' ') objects already compiled"
      retarget_legacy_toolchain "$source_dir" "$toolchain_dir"
    else
      rm -rf out
    fi
    mkdir -p out
    printf '{"wrapper": "%s", "patches": "%s", "node": "%s"}\n' \
      "$wrapper_hash" "$patch_set" "$node_version" > "out/$stamp_file"

    # `--dest-os=mac` is the right answer even though the target is iOS. Node's
    # configure passes the dest-os straight to gyp as `OS`, and gyp knows only
    # mac, win and linux: `OS=ios` matches none of the platform blocks, so gyp
    # falls back to its linux defaults — Node's own gyp then links the host
    # tools with `-Wl,--start-group`, which ld64 rejects, and compiles with
    # `-D_LARGEFILE_SOURCE`. Naming mac keeps the platform layer native and
    # leaves the actual target to the compiler wrapper, which is the only place
    # that knows a build is split between a macOS host and an iOS target.
    # configure is what makes a reused tree expensive: it rewrites the generated
    # makefiles and their prerequisites, so make then rebuilds everything below
    # them. A tree whose stamp matches was configured by these exact wrappers, so
    # its out/ is already the output of this configuration and configure is
    # skipped.
    if [ "$reused" = 0 ]; then
      if ! configure_node --dest-os=mac 2>"$work_dir/configure-mac.log"; then
        say "Node's configure does not accept --dest-os=mac; retrying as an ios build"
        cat "$work_dir/configure-mac.log" >&2
        rm -rf out
        configure_node --dest-os=ios \
          || fail "configure failed both ways — read $work_dir/configure-mac.log"
      fi
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

  # `make` compiles the library but stages no public headers: `out/Release/include/
  # node` is produced by tools/install.py's headers-only mode (the same script the
  # `tar-headers` Make target runs), not by the compile. The first run that got
  # past compiling died on `cp -R out/Release/include/node` being absent -- so
  # generate the layout instead of assuming it.
  local header_layout="$source_dir/out/Release/include/node"
  if [ ! -d "$header_layout" ]; then
    local py
    py=$(command -v python3 || command -v python || true)
    [ -n "$py" ] || fail "no python3 on PATH to stage Node's public headers"
    ( cd "$source_dir" && "$py" tools/install.py install --headers-only \
        --dest-dir out/Release --prefix / ) \
      || fail "tools/install.py could not stage Node's public headers"
  fi
  [ -d "$header_layout" ] || fail "no headers under out/Release/include/node even after install.py"

  mkdir -p "$vendor_dir/lib" "$vendor_dir/include"
  cp "$dylib" "$vendor_dir/lib/libnode.dylib"
  install_name_tool -id "@rpath/libnode.dylib" "$vendor_dir/lib/libnode.dylib"
  rm -rf "$vendor_dir/include/node"
  cp -R "$header_layout" "$vendor_dir/include/node"

  say "linking target check"
  lipo -info "$vendor_dir/lib/libnode.dylib"
  otool -l "$vendor_dir/lib/libnode.dylib" | grep -A2 LC_BUILD_VERSION | head -n 6
}

# ── the session lock: native/system's flock addon, rebuilt for iOS ───────────

# `session-persistence-jsonl` and `session-persistence-sqlite` take their rewrite
# lock from @deepseek-ai/node-addon-system, which publishes one `system.node` per
# platform and has no iOS package. `flock.ts` resolves
# `@deepseek-ai/node-addon-system-<platform>-<arch>/bin/system.node`, and this
# build reports `darwin` (see the --dest-os note above) on arm64, so the file it
# opens on a phone is the macOS package's. That one is macOS-only code, and the
# load would fail at the first save. Rather than teach the phone a new platform
# name, replace that binary: `flock.c` is 300 lines of stable Node-API over a
# single `flock(LOCK_EX | LOCK_NB)`, and libSystem has that syscall on iOS.
#
# Two things make this a packaging step rather than a compile:
#
#   1. It has to run after both halves — node_api.h comes from the headers
#      stage_node installs, and the destination lives inside the harness
#      stage_harness deploys.
#   2. A `.node` is dlopen'd, and iOS will not map executable code that carries
#      no signature, so it is ad-hoc signed here (`--sign -`). The app seal covers
#      the file's bytes; the code signature is what dyld checks. The toolchain that
#      re-signs the .ipa later re-seals the bundle around this file.
stage_system_addon() {
  say "building native/system's flock addon for iOS"
  command -v xcrun >/dev/null || fail "xcrun is missing — this step needs Xcode"

  local sdk source package_dir
  sdk=$(xcrun --sdk iphoneos --show-sdk-path) || fail "no iPhoneOS SDK is installed"
  source="$root/native/system/packages/entry/src/flock.c"
  [ -f "$source" ] || fail "native/system's flock.c is missing from this checkout"
  [ -f "$vendor_dir/include/node/node_api.h" ] \
    || fail "Node's headers are not staged — the addon compiles against them (run the Node half first)"

  # The name is not a guess: `process.platform` on this build is `darwin` and
  # `process.arch` is `arm64`, and flock.ts builds the package name from those.
  package_dir="$engine_dir/runtime/harness/node_modules/@deepseek-ai/node-addon-system-darwin-arm64"
  [ -f "$package_dir/package.json" ] \
    || fail "the deployed harness has no node-addon-system-darwin-arm64 — pnpm deploy must keep it (flock.ts require.resolve()s its package.json)"

  mkdir -p "$package_dir/bin"
  # Same flags native/system/scripts/build.ts uses for the macOS build, with the
  # iOS target swapped in: -bundle/-undefined dynamic_lookup because the addon
  # resolves Node's symbols at load, and NAPI_VERSION=8 because that is the
  # version the binding declares.
  xcrun --sdk iphoneos clang \
    -target "arm64-apple-ios$ios_min" -isysroot "$sdk" \
    -std=c11 -O2 -fPIC -fvisibility=hidden -DNAPI_VERSION=8 \
    -I "$vendor_dir/include/node" \
    -bundle -undefined dynamic_lookup \
    -o "$package_dir/bin/system.node" "$source" \
    || fail "the flock addon did not compile against the iPhoneOS SDK"

  codesign --force --sign - "$package_dir/bin/system.node" \
    || fail "could not ad-hoc sign the flock addon — an unsigned .node will not dlopen on a device"

  say "flock addon staged"
  # printf-only fallback: a missing `lipo`/`file` must not turn a good build into
  # a failed one under `set -e`.
  lipo -info "$package_dir/bin/system.node" 2>/dev/null \
    || file "$package_dir/bin/system.node" 2>/dev/null || true
  printf 'prepare-engine: %s\n' "$package_dir/bin/system.node"
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
# It needs both halves, so a half-run says what is missing instead of failing:
# --node-only stages no harness to put it in, and --harness-only cannot compile
# without the headers the Node half installs.
if [ "$run_harness" -eq 1 ] && [ -f "$vendor_dir/include/node/node_api.h" ]; then
  stage_system_addon
elif [ "$run_harness" -eq 1 ]; then
  say "skipping the flock addon: Node's headers are not staged, so there is nothing to compile against"
fi

say "done"
cat <<'NOTE'
Next:
  1. tooling/ios/build.sh iphoneos <output-dir>   # xcodegen + xcodebuild
  2. Sign and install the .ipa with your own toolchain.
Open the app, choose 本机引擎, and read Library/Logs/engine.log in the app
container if it does not come up. Session saving needs the flock addon this
script stages into the harness; how that is verified (and what is still
unproven) is in app/ios/Engine/README.md.
NOTE
