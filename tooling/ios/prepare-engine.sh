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
  # The app's window is a WKWebView pointed at the harness's own server, so the
  # deploy has to carry a built page: `apps/web/dist` is vite output, gitignored
  # and never produced by `build:lib:host`. Three steps, in this order —
  # `build:lib:client` emits the client-face `lib/` products the vite entry
  # imports ("workspace packages are consumed as built lib products", see
  # apps/web/vite.config.ts), and `build:web` is the vite build itself. Without
  # the dist the server answers every page request with a 404 and the window
  # stays blank, with no engine-log line to say why: the missing page is a
  # request-time concern of the frontend-static owner, not a boot failure.
  pnpm run build:lib:host
  # `build:lib:host` already asks node for an 8 GB old space: the host program is
  # big. The client aggregate (`tsconfig.client.json`, ~130 referenced projects)
  # is the same size of program and was left on node's default ceiling, which a
  # 7 GB macOS runner reaches — `tsc -b tsconfig.client.json` aborted with
  # SIGABRT (exit 134, V8's fatal dump in the log) and took the deploy with it.
  # The ceiling only has to sit above what the build actually needs.
  NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=8192" pnpm run build:lib:client
  pnpm run build:web
  [ -f apps/web/dist/index.html ] \
    || fail "build:web produced no apps/web/dist/index.html — the app window would load a blank page"

  rm -rf "$engine_dir/runtime/harness"
  mkdir -p "$engine_dir/runtime"
  # `strictDepBuilds` is off for this one call. The only unapproved build script in
  # the closure is this repository's own `@deepseek-ai/dsh-subprocess-local`
  # postinstall (it restores the executable bit on node-pty's macOS spawn helper),
  # and pnpm cannot match it against an `allowBuilds` key: deploy resolves a
  # workspace dependency to an absolute `file://` URL, so the entry is looked up as
  # `...@file:///Users/runner/...` and a name-only key does not match. pnpm 11 turns
  # an unmatched script into a hard error rather than a warning. Turning the check
  # off here keeps the review list in pnpm-workspace.yaml meaningful for registry
  # packages (koffi, esbuild, node-pty still need their entries) without inventing a
  # machine-specific key for a package that lives in this checkout.
  pnpm --config.strictDepBuilds=false --filter @deepseek-ai/dsh --prod deploy "$engine_dir/runtime/harness"

  # `deploy` carries the deployed package's `dependencies` and leaves peer
  # dependencies to the consumer. See stage_harness_peers for what that costs and
  # how the gaps are closed.
  # `native/system` is a separate tsconfig root the host build does not reach.
  #
  # `@deepseek-ai/node-addon-system` exports `./landlock-run` -> `./lib/index.js`,
  # and `sandbox-local` imports that subpath statically. The host aggregate
  # (`tsc -b` over `tsconfig.host.json`) does reference the entry project, but
  # `build:lib:host` drives `host-libraries`, whose compiler step only walks the
  # aggregate's references from `packages/`; the deployment therefore carried the
  # package with no `lib/`, and every import through the subpath failed at run
  # time while the tree looked complete.
  #
  # Building it here is the narrow fix: it is one project, it is already declared
  # composite with `outDir: lib`, and it is needed by a package the web profile
  # mounts on iOS.
  # This function runs from the repository root (the lockfile check above proves
  # it), and `pnpm` is already required here.
  if [ -d native/system ]; then
    ( cd native/system && pnpm run build:ts ) \
      || fail "native/system's TypeScript did not build — sandbox-local imports its landlock-run subpath"
  fi

  stage_harness_peers "$engine_dir/runtime/harness"

  # Before anything is measured or staged on top: a deploy made on a Mac carries
  # the macOS and Windows builds of every package that has them, plus each wasm
  # backend, and none of that can load here. See prune_foreign_platform_packages.
  prune_foreign_platform_packages "$engine_dir/runtime/harness"

  # `host.mjs` imports `lib/bin.js`; without it the app boots and fails at once,
  # so the staging step refuses to leave a half-filled Engine/ behind.
  [ -f "$engine_dir/runtime/harness/lib/bin.js" ] \
    || fail "deploy produced no lib/bin.js — check that build:lib:host succeeded"
  [ -f "$engine_dir/host.mjs" ] || fail "Engine/host.mjs is missing"

  du -sh "$engine_dir/runtime/harness"
}

# ── the peer packages `pnpm deploy` does not carry ───────────────────────────

# `deploy` copies the deployed package's `dependencies` and nothing else, while a
# peer dependency is the consumer's to provide. The consumers are the packages in
# that closure: `packages/util/atomic-write` peers `@deepseek-ai/dsh-error`,
# `packages/shell/tool-bash` peers `@deepseek-ai/dsh-shell`, and so on -- service
# definitions whose implementation imports them at run time. In the repository the
# link is always there, because the workspace installs every package at the root;
# in the deployed tree it is not, so the first import throws
# `ERR_MODULE_NOT_FOUND` and the app can only report that the engine exited.
# Eleven such packages were missing from a deploy of `@deepseek-ai/dsh` when this
# was written.
#
# So the deployed tree is checked against itself: every `@deepseek-ai/*` module the
# first-party output imports has to resolve inside it. A gap is copied in from this
# checkout, and a gap this checkout does not build fails the staging step. Fill,
# then check again -- a copied package imports modules of its own.
#
# The second gap is the copies' own dependencies. `deploy` links every package it
# carries into the store -- `node_modules/<name> -> .pnpm/<name>@<version>/
# node_modules/<name>` -- and a store package finds its dependencies as sibling
# links in that same directory. A copy made here is a plain directory with no
# siblings, so each of its `dependencies` has to sit in `node_modules` itself, or
# its first import throws `ERR_MODULE_NOT_FOUND`. A dependency the store already
# holds is linked, not copied: the bytes are in the tree, and the store entry
# resolves its own dependencies the way pnpm laid them out.

# The `@deepseek-ai/*` modules the deployed first-party output imports, one per
# line, sorted. Only built output is read: the CLI's own `lib/`, and `lib/` inside
# each deployed workspace package. A client-only package ships a bundle for the
# WebView instead of `lib/`, and the browser resolves those imports, not Node.
harness_imports() {
  local harness="$1"
  {
    grep -RhoE "(from|import|require)[ ]*\(?[ ]*['\"]@deepseek-ai/[A-Za-z0-9._-]+" \
      --include='*.js' --include='*.mjs' \
      "$harness/lib" "$harness"/node_modules/@deepseek-ai/*/lib 2>/dev/null || true
  } | sed -E "s/.*['\"](@deepseek-ai\/[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*)$/\1/" | sort -u
}

# The modules in that list the deployed tree cannot resolve, asked the way Node asks.
#
# Checking a fixed pair of directories is not the same question. `deploy` puts a
# store package's own dependencies in `.pnpm/<pkg>@<hash>/node_modules`, beside the
# package rather than at the tree root, so a name can be resolvable from the root
# and still be unreachable from the file that imports it. That is what a device
# showed: `dsh-bash-sandbox` is a store package, its peer `dsh-bash-local` was never
# staged, and the old root-level check saw a directory the importing file's real
# path never walks to -- five plugins failed to import while the check reported
# nothing.
#
# So each import is resolved from the file that has it, after `realpath`: the same
# algorithm Node runs. A name no import site can reach is a gap; one that some
# sites reach is still reported, because whatever fails to import is a plugin that
# will not mount.
harness_missing_peers() {
  local harness="$1"
  # Both the top-level links and the store they point at. `grep -R` does not
  # descend through a symbolic link, and `pnpm deploy` makes every package
  # `node_modules/@deepseek-ai/<name>` a link into `.pnpm`; a package that exists
  # only in the store would otherwise never be read, and its peers never reported.
  grep -RHoE "(from|import|require)[ ]*\(?[ ]*['\"]@deepseek-ai/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*" \
    --include='*.js' --include='*.mjs' \
    "$harness/lib" \
    "$harness"/node_modules/@deepseek-ai/*/lib \
    "$harness"/node_modules/.pnpm/node_modules/@deepseek-ai/*/lib 2>/dev/null \
    | node -e '
      const fs = require("fs");
      const { createRequire } = require("module");
      // `<file>:<matched text>`: the matched text holds no colon of its own, so
      // the last one in the line separates them whatever the path contains.
      const LINE = /^(.*):.*[\x27"](@deepseek-ai\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)$/;
      const unresolved = new Set();
      const realpaths = new Map();
      for (const line of fs.readFileSync(0, "utf8").split("\n")) {
        const found = line.match(LINE);
        if (found === null) continue;
        const file = found[1];
        const name = found[2];
        let path = realpaths.get(file);
        if (path === undefined) {
          try {
            path = fs.realpathSync(file);
          } catch {
            path = file;
          }
          realpaths.set(file, path);
        }
        try {
          createRequire(path).resolve(name);
        } catch {
          unresolved.add(name);
        }
      }
      for (const name of unresolved) console.log(name);
    '
}

# The packages in the tree that are real directories instead of links into the
# store: the ones this script copied. They are the only ones whose dependencies
# have to be resolved from `node_modules` itself.
harness_copied_packages() {
  local harness="$1" dir
  for dir in "$harness"/node_modules/* "$harness"/node_modules/@*/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    case "${dir##*/}" in
      .pnpm|.bin|node_modules) continue ;;
    esac
    [ -f "$dir/package.json" ] && printf '%s\n' "$dir"
  done
}

# The dependency names a manifest declares, for a package copied into the tree.
# Both `dependencies` and `peerDependencies`: an optional dependency stays out,
# because it is absent by design on a platform that does not offer it -- the
# platform-specific prebuilds are exactly that.
#
# A peer belongs to this list here, unlike in the deploy's own closure. A store
# package finds its peers as sibling links pnpm laid out beside it; a copy made by
# stage_harness_package carries no `node_modules` at all (`tar --exclude`), so a
# peer it imports resolves from the tree root or not at all. Reading only
# `dependencies` is what shipped a harness that booted with no window:
# `dsh-session-persistence` is copied, and `@deepseek-ai/dsh-session` is its PEER,
# so nothing staged the module it imports. The top-level link to `dsh-session`
# happened to exist, which kept harness_missing_peers from noticing, while the
# copy's own resolution -- the one Node performs -- failed with
# ERR_MODULE_NOT_FOUND.
manifest_dependencies() {
  node -e '
    const { readFileSync } = require("fs");
    const manifest = JSON.parse(readFileSync(process.argv[1], "utf8"));
    const names = new Set([
      ...Object.keys(manifest.dependencies || {}),
      ...Object.keys(manifest.peerDependencies || {}),
    ]);
    for (const name of names) console.log(name);
  ' "$1"
}

# The dependencies of the copied packages that the tree cannot resolve from them.
harness_missing_copied_dependencies() {
  local harness="$1" dir manifest dep
  while IFS= read -r dir; do
    manifest="$dir/package.json"
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ -e "$harness/node_modules/$dep" ] || printf '%s\n' "$dep"
    done < <(manifest_dependencies "$manifest")
  done < <(harness_copied_packages "$harness")
}

# Where this checkout keeps a package. Two answers, in this order.
#
# The installed tree first, because it is what `deploy` itself read: a package the
# root does link is one `existsSync` away. It is not enough on its own, though --
# a peer dependency is by definition the name no manifest in the deploy's closure
# declares as its own, so the store has no entry for it, and a workspace package
# that only *other* packages peer on has no link in the root `node_modules`
# either. Asking only the install turned every such gap into a hard failure
# (`CI #40: @deepseek-ai/dsh-attachment`), which is the one outcome this step
# exists to avoid.
#
# So the checkout is asked second, by name, over the directories
# `pnpm-workspace.yaml` globs (`packages/*/*`, `apps/*`, `vendor/*`,
# `native/system/packages/*`): the sources are all here, and `build:lib:host` has
# just built each package's `lib/` in place, which is what the copy below needs.
workspace_package_dir() {
  node -e '
    const { createRequire } = require("module");
    const { existsSync, readdirSync, readFileSync } = require("fs");
    const { join } = require("path");
    const [root, name] = process.argv.slice(1);

    const request = createRequire(root + "/package.json");
    for (const base of request.resolve.paths(name) || []) {
      const dir = base + "/" + name;
      if (existsSync(dir + "/package.json")) { console.log(dir); process.exit(0); }
    }

    // The workspace globs are `packages/*/*`, `apps/*`, `vendor/*`,
    // `native/system/packages/*` and `website`, so three levels below those
    // directories reach every member. Nothing deeper is entered: the trees below
    // them (`skills/*/templates`, test fixtures) hold manifests that are not
    // workspace members, and walking them costs more than the answer is worth.
    const skip = new Set(["node_modules", "lib", "dist", "coverage"]);
    const manifestName = (dir) => {
      const manifest = join(dir, "package.json");
      if (!existsSync(manifest)) return undefined;
      try {
        return JSON.parse(readFileSync(manifest, "utf8")).name;
      } catch {
        return undefined;
      }
    };
    const walk = (dir, depth) => {
      if (manifestName(dir) === name) return dir;
      if (depth === 0) return undefined;
      let entries;
      try {
        entries = readdirSync(dir, { withFileTypes: true });
      } catch {
        return undefined;
      }
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        if (entry.name.startsWith(".") || skip.has(entry.name)) continue;
        const found = walk(join(dir, entry.name), depth - 1);
        if (found !== undefined) return found;
      }
      return undefined;
    };
    let found;
    for (const top of ["packages", "apps", "vendor", "native", "website"]) {
      found = walk(join(root, top), 3);
      if (found !== undefined) break;
    }
    if (found === undefined) process.exit(1);
    console.log(found);
  ' "$root" "$1"
}

stage_harness_package() {
  local harness="$1" name="$2"
  # Its own statement: `local x=1 y=$x` expands `$x` before `local` runs, which
  # under `set -u` is an unbound variable rather than an empty one.
  local target="$harness/node_modules/$name" source link
  # `-e`, not `-L`: a link an earlier run left behind may be the very thing that
  # does not resolve, and that is a package to stage, not one to keep.
  [ -e "$target" ] && return 0
  mkdir -p "$(dirname "$target")"
  if [ -d "$harness/node_modules/.pnpm/node_modules/$name" ]; then
    # The link target is relative to the link's own directory, which is
    # `node_modules/` for an unscoped name and `node_modules/<scope>/` for a
    # scoped one — hence one `../` less than the name has segments. Relative, so
    # the tree stays movable: the deploy is copied into DPSK.app and the absolute
    # path it has here is not the one it has there.
    case "$name" in
      */*) link="../.pnpm/node_modules/$name" ;;
      *) link=".pnpm/node_modules/$name" ;;
    esac
    say "the deploy left $name out; linking it from the store"
    rm -f "${target:?}"
    ln -s "$link" "$target"
    # A link that exists is not a package that loads: the store entry can be
    # present and still lack what this package resolves at run time. Presence is
    # all this function can decide -- whether the whole tree loads is
    # stage_harness_peers' question, answered once every name has been staged.
    if [ -e "$target" ]; then
      return 0
    fi
    say "the store's $name does not resolve from node_modules; copying it instead"
    rm -f "${target:?}"
    source=$(cd "$harness/node_modules/.pnpm/node_modules/$name" && pwd -P) || source=""
    if [ -n "$source" ]; then
      cp -RL "$source" "$target"
      # A store copy can be a link farm into a store entry that the deploy did not
      # carry in full; the workspace copy below is the one this script owns.
      if [ -e "$target/package.json" ]; then
        return 0
      fi
      say "the store's $name has no manifest; taking it from the workspace"
    fi
    rm -rf "${target:?}"
    source=$(workspace_package_dir "$name") \
      || fail "the deployed harness needs $name, and this checkout has no workspace package by that name"
    mkdir -p "$target"
    tar -C "$source" -chf - --exclude='*node_modules*' . \
      | tar -C "$target" -xf - \
      || fail "could not copy $name out of this checkout"
    return 0
  fi
  source=$(workspace_package_dir "$name") \
    || fail "the deployed harness needs $name, and this checkout has no workspace package by that name"
  say "the deploy left $name out; taking it from the workspace"
  rm -rf "${target:?}"
  mkdir -p "$target"
  # Not `cp -R`: pnpm gives every package in the checkout its own `node_modules`,
  # full of links into the store, and copying that duplicates the whole closure
  # inside the copy -- the deployed tree would grow by more than the package does.
  # The copy gets no dependency links at all; every name its manifest declares is
  # staged beside it by harness_missing_copied_dependencies instead.
  #
  # `tar` because the exclusion is the point. `-h` dereferences what the package
  # itself links to, so the copy carries no link back into this checkout.
  tar -C "$source" -chf - --exclude='*node_modules*' . \
    | tar -C "$target" -xf - \
    || fail "could not copy $name out of this checkout"
}

# The imports that resolve to nothing even though the directory check above
# accepted them: a staged package whose built entry is missing (`lib/` absent)
# answers the directory check and fails on the first import at run time.
#
# Each import is resolved from the file that has it, after `realpath`. The
# question is the one Node asks: a package inside the deploy's store finds its
# dependencies as sibling links in the store, which the CLI's own resolution
# root does not see -- asking from `lib/bin.js` alone reports packages that are
# right there. The same goes for the top-level links: a link's own path is the
# store entry's only after it is followed.
#
# Reported, not fatal -- which files a package publishes is its own manifest's
# business, and a client-only package is imported by the bundle in the WebView,
# not by Node -- but on stderr, because a name here is the harness failing at
# boot with an empty window, the symptom this whole step exists to prevent.
harness_unresolvable_imports() {
  local harness="$1"
  [ -f "$harness/lib/bin.js" ] || return 0
  grep -RHoE "(from|import|require)[ ]*\(?[ ]*['\"]@deepseek-ai/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*" \
    --include='*.js' --include='*.mjs' \
    "$harness/lib" \
    "$harness"/node_modules/@deepseek-ai/*/lib \
    "$harness"/node_modules/.pnpm/node_modules/@deepseek-ai/*/lib 2>/dev/null \
    | node -e '
      const fs = require("fs");
      const { createRequire } = require("module");
      // `<file>:<matched text>`: the matched text carries no colon, so the last
      // one in the line is the separator, whatever the path holds.
      const LINE = /^(.*):.*[\x27"](@deepseek-ai\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)$/;
      const failing = new Map();
      const resolving = new Set();
      const realpaths = new Map();
      for (const line of fs.readFileSync(0, "utf8").split("\n")) {
        const found = line.match(LINE);
        if (found === null) continue;
        const file = found[1];
        const name = found[2];
        let path = realpaths.get(file);
        if (path === undefined) {
          try {
            path = fs.realpathSync(file);
          } catch {
            path = file;
          }
          realpaths.set(file, path);
        }
        try {
          createRequire(path).resolve(name);
          resolving.add(name);
        } catch {
          failing.set(name, (failing.get(name) || 0) + 1);
        }
      }
      for (const name of failing.keys()) {
        console.log(name + (resolving.has(name) ? " (some import sites resolve)" : ""));
      }
    '
}


# Temporary diagnostic for the staging investigation: for every first-party package
# in the tree, report the specifiers its own lib imports that do not resolve from
# it, whether the tree has the package at all, and which file it came from.
harness_peer_report() {
  local harness="$1"
  grep -RHoE "(from|import|require)[ ]*\(?[ ]*['\"]@deepseek-ai/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*" \
    --include='*.js' --include='*.mjs' \
    "$harness/lib" \
    "$harness"/node_modules/@deepseek-ai/*/lib \
    "$harness"/node_modules/.pnpm/node_modules/@deepseek-ai/*/lib 2>/dev/null \
    | node -e '
      const fs = require("fs");
      const { createRequire } = require("module");
      const LINE = /^(.*):.*[\x27"](@deepseek-ai\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)$/;
      const seen = new Set();
      for (const line of fs.readFileSync(0, "utf8").split("\n")) {
        const found = line.match(LINE);
        if (found === null) continue;
        const file = found[1];
        const name = found[2];
        if (seen.has(file + "\\0" + name)) continue;
        seen.add(file + "\\0" + name);
        let real = file;
        try {
          real = fs.realpathSync(file);
        } catch {
          // keep the given path
        }
        try {
          createRequire(real).resolve(name);
        } catch (error) {
          const pkg = name.startsWith("@") ? name.split("/").slice(0, 2).join("/") : name.split("/")[0];
          console.log("UNRESOLVED " + name + "  from " + real + "  code=" + (error.code ?? "?") + "  pkgdir=" + pkg);
        }
      }
    '
}

stage_harness_peers() {
  local harness="$1" passes=0 gaps name
  while :; do
    passes=$((passes + 1))
    [ "$passes" -le 8 ] \
      || fail "the deployed harness still needs packages that are not in it: $( { harness_missing_peers "$harness"; harness_missing_copied_dependencies "$harness"; } | sort -u | tr '\n' ' ')"
    gaps=$( { harness_missing_peers "$harness"; harness_missing_copied_dependencies "$harness"; } | sort -u)
    [ -n "$gaps" ] || break
    # A here-document rather than a pipe: the loop has to run in this shell, or a
    # `fail` inside it would only end a subshell and the staging step would carry
    # on with a tree that is known to be incomplete.
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # A gap is an import site's specifier, which may name a subpath
      # (`@scope/pkg/sub`). Staging works on packages, so the subpath is dropped
      # here; the package is what has to be present, and the subpath belongs to its
      # own `exports`.
      case "$name" in
        # Scoped with a subpath: keep the scope and the package name.
        @*/*/*) stage_harness_package "$harness" "${name%/*}" ;;
        *) stage_harness_package "$harness" "$name" ;;
      esac
    done <<EOF
$gaps
EOF
  done
  # The loop only guarantees every name is *present*. Presence is not loading: a
  # copy can carry a manifest and still lack the entry its `exports` names, and a
  # store link can point at a partial entry. `harness_unresolvable_imports` below
  # resolves each import from its own file, which is what turns that into a line in
  # the build log instead of a plugin that fails to mount on the device.
  # Temporary diagnostic: what do the import sites actually see?
  say "peer resolution report:"
  harness_peer_report "$harness" >&2 || true

  local unresolvable
  unresolvable=$(harness_unresolvable_imports "$harness")
  if [ -n "$unresolvable" ]; then
    # A warning, not a failure: the packages are in the tree and their `lib/` is
    # the Mac build's to produce. But a name here is the app opening an empty
    # window, so it goes to stderr where a build log keeps it apart from progress.
    printf 'warning: these packages are in the harness but nothing they import resolves to them -- their built output is missing, and the app will fail on the first import: %s\n' \
      "$(printf '%s ' $unresolvable)" >&2
  fi
}

# ── the packages that exist only for another platform ────────────────────────

# The Mach-O rule below reads files, so it cannot see the weight that is not a
# binary: LibreOffice's engine is one 141 MB executable beside 13 MB of data, and
# a WebAssembly engine carries no Mach-O at all -- `@deepseek-ai/libreoffice-kit-wasm`
# is 145 MB of `.wasm` and assets. Both are useless on this device: the wasm engine
# needs a JIT, which the app refuses to ask for (the engine runs `--jitless`, see
# app/ios/README.md), and the macOS engine cannot be dlopened. The names are what
# these packages have in common: npm gives a platform package the triple it was
# built for, `-darwin-arm64`, `-win32-x64`, `-linux-x64`, ... and a wasm backend
# `-wasm`. So the whole package goes, not just its files.
#
# Deleting the package is also the smaller change for the consumer: a package that
# is absent is reported as "not available" (`@deepseek-ai/libreoffice-kit`'s
# resolver falls through to the next engine), while a package whose binary was
# deleted reports "failed to load". Every consumer of these is lazy -- office-kit
# imports its engine inside `resolve()`, sharp and node-pty inside the first call
# that needs them, sherpa-onnx inside the voice-input plugin -- so no boot path
# imports one, and nothing on the device loses a capability it had: the binaries
# were already unloadable.
#
# Two names this rule cannot read: both are native addons this script rebuilds
# for iOS and leaves named for darwin, because that is what Node reports for
# `process.platform` here (see stage_system_addon and stage_require_builtin).
# They are staged after this runs; the keep-list is here so a later reordering
# cannot cost the app its session store or its ability to boot at all.
#
# `node-addon-require-builtin-darwin-arm64` is not optional on this platform:
# `dsh-app-boot` asks it for Node's internal module loaders while preparing the
# profile, so without it the engine never reaches a listening port.
#
# A name that only mentions a platform is not one of these: `@deepseek-ai/dsh-win32-process`
# implements Windows support in JavaScript and ships on every platform, so the
# architecture after the OS is what tells a platform package from a package about a
# platform. The OS token alone would delete it, and with it the harness.
prune_foreign_platform_packages() {
  local harness="$1" before after path name kept=0 removed=0
  local os='darwin|win32|linux|android|freebsd|openbsd|netbsd|sunos'
  local arch='x64|x86_64|arm64|aarch64|ia32|x86|arm|armv7|armv7l|ppc64|ppc64le|s390x|riscv64|universal'
  local triple="(^|[-_])($os)[-_]($arch)([-_].*)?\$"
  say "dropping the packages built for another platform"
  before=$(du -sm "$harness" | cut -f1)
  while IFS= read -r -d '' path; do
    # A directory already gone went with its parent, which was one of these.
    [ -d "$path" ] || continue
    name=${path##*/}
    # pnpm decorates a store entry with its version (`name@1.2.3`) and a scoped
    # one with its scope (`@scope+name@1.2.3`); the package name is what is left,
    # and `+` is punctuation like `-`, so a triple can follow it directly
    # (`@esbuild+darwin-arm64`).
    name=${name%@*}
    name=${name//+/-}
    case "$name" in
      *node-addon-system-darwin-arm64* | *node-addon-require-builtin-darwin-arm64*)
        kept=$((kept + 1))
        continue
        ;;
    esac
    if [[ ! $name =~ $triple && ! $name =~ -wasm$ ]]; then
      continue
    fi
    say "  dropping ${path#"$harness/node_modules/"}"
    rm -rf "${path:?}"
    removed=$((removed + 1))
  done < <(find "$harness/node_modules" -type d \
             \( -name '*darwin*' -o -name '*win32*' -o -name '*linux*' -o -name '*android*' \
                -o -name '*bsd*' -o -name '*sunos*' -o -name '*-wasm' \) -print0 2>/dev/null)

  # What is left of a Windows-only package that is not itself a package: node-pty
  # ships ConPTY's `.pdb` and `.dll` inside its own tarball, where the name rule
  # above has no package to delete. No iOS process opens any of these extensions.
  find "$harness/node_modules" -type f \
    \( -name '*.pdb' -o -name '*.dll' -o -name '*.exe' -o -name '*.lib' -o -name '*.def' \) \
    -delete 2>/dev/null || true

  # A deleted store entry leaves the top-level link that pointed at it dangling,
  # and a dangling link is worse than an absent package: Node reports it as an
  # installed package that is broken.
  find "$harness/node_modules" -xtype l -delete 2>/dev/null || true
  find "$harness/node_modules" -depth -type d -empty -delete 2>/dev/null || true

  after=$(du -sm "$harness" | cut -f1)
  say "dropped $removed packages built for another platform; the harness is $before MB -> $after MB"
  if [ "$kept" -gt 0 ]; then
    say "kept $kept path(s) named for darwin that are built for iOS"
  fi
}

# ── the other platforms' binaries the deploy carries ─────────────────────────

# `deploy` resolves `optionalDependencies` for the machine that runs it -- a Mac --
# so the tree holds prebuilt binaries for every platform a package offers: sharp
# and its libvips, sherpa-onnx, koffi, ripgrep, node-pty's spawn helpers and
# LibreOffice's `dsoffice`, built for macOS, beside the Windows and Linux
# prebuilds of the packages that ship them. iOS loads none of them: dyld refuses a
# Mach-O whose platform is not iOS, so requiring one of these fails on the device
# whether the file is there or not, and the file is only weight in the bundle. The
# first deploy measured 16 macOS Mach-O in 199 MB, most of it `dsoffice`, a
# desktop executable the app could never start.
#
# Two rules, because a directory name and a file's build target do not always
# agree: the directories that name another platform go first (they also carry the
# Windows and Linux files `otool` would never be asked about), then every
# remaining Mach-O is asked what it was built for and dropped when the answer names
# another platform. What this script stages itself -- Node's headers,
# `libnode.dylib`, the flock addon -- is iOS by construction and survives the
# second rule.
prune_non_ios_binaries() {
  local harness="$1" before after removed=0 unreadable=0 path listing
  say "dropping the binaries built for other platforms"
  # Without these two the second rule would read every Mach-O as "not iOS" and
  # delete the flock addon this script just built, so they are checked first.
  command -v file >/dev/null 2>&1 || fail "file(1) is missing — the pruning step cannot tell a Mach-O apart"
  command -v otool >/dev/null 2>&1 || fail "otool is missing — the pruning step cannot tell an iOS binary apart"
  before=$(du -sm "$harness" | cut -f1)

  # `darwin-*` is the Mac: the store names `@esbuild/darwin-x64` and friends that
  # way, and node-pty ships `prebuilds/darwin-x64` beside `darwin-arm64`. An iOS
  # build never lands under a name like that, so the whole directory goes.
  find "$harness/node_modules" -type d \
    \( -name 'win32-*' -o -name 'win32_*' -o -name 'linux-*' -o -name 'linux_*' \
       -o -name 'android-*' -o -name 'android_*' -o -name 'freebsd-*' \
       -o -name 'openbsd-*' -o -name 'sunos-*' -o -name 'wasm32-*' \
       -o -name 'darwin-*' -o -name 'darwin_*' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true

  # `file` decides what is worth asking `otool` about: the tree has tens of
  # thousands of files and only a handful are Mach-O. `otool -l` prints one
  # `platform` line per slice, so a fat binary that carries an iOS slice is kept.
  # `-perm -100` rather than `-u+x`, which BSD find does not take.
  #
  # Three answers, and only one of them deletes. IOS keeps the file, another
  # platform drops it, and *no* platform line at all -- otool failed, or the file
  # predates LC_BUILD_VERSION -- keeps it: `command -v` proves otool exists, not
  # that it runs (a bootstrap's llvm-otool execs an `otool-classic` that may be
  # absent), and a probe that cannot answer must not cost the app a binary dyld
  # needs. Such a run removes nothing and says so.
  while IFS= read -r -d '' path; do
    case "$(file -b "$path" 2>/dev/null)" in
      Mach-O*) ;;
      *) continue ;;
    esac
    listing=$(otool -l "$path" 2>/dev/null || true)
    case "$listing" in
      *'platform IOS'*|*LC_VERSION_MIN_IPHONEOS*) continue ;;
    esac
    if ! printf '%s\n' "$listing" \
        | grep -qE 'platform (MACOS|MACCATALYST|TVOS|WATCHOS|BRIDGEOS|DRIVERKIT|XROS)'; then
      unreadable=$((unreadable + 1))
      continue
    fi
    rm -f "$path"
    removed=$((removed + 1))
  done < <(find "$harness/node_modules" -type f \
             \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -perm -100 \) -print0)

  # A platform directory leaves its package behind as an empty shell.
  find "$harness/node_modules" -depth -type d -empty -delete 2>/dev/null || true

  after=$(du -sm "$harness" | cut -f1)
  say "dropped $removed Mach-O files built for another platform; the harness is $before MB -> $after MB"
  if [ "$unreadable" -gt 0 ]; then
    say "$unreadable Mach-O files named no platform at all and were kept — otool could not describe them"
  fi
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
  # Two tiers, not one: sources at 2000, everything under out/ at 2001. Equal
  # timestamps are the subtle case -- the archive keeps nanoseconds that `touch -t`
  # zeroes, so "equal" can still compare as older and rebuild the world. Strictly
  # newer is not ambiguous, and both are in the past so nothing reports clock skew.
  find "$source_dir" -path "$source_dir/out" -prune -o -type f \
    -exec touch -t 200001010000 {} + 2>/dev/null || true
  find "$source_dir/out" -type f -exec touch -t 200101010000 {} + 2>/dev/null || true
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
    # 2002: newer than every object (2001), so make rebuilds exactly what a patch
    # changed and nothing else.
    [ -n "$rel" ] && [ -f "$source_dir/$rel" ] && touch -t 200201010000 "$source_dir/$rel"
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

  if [ -n "${DPSK_CCACHE:-}" ]; then
    # The numbers that decide whether the next run is minutes or hours.
    say "ccache after the build"
    "$DPSK_CCACHE" --show-stats 2>/dev/null | sed -n '1,12p' || true
  fi

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

  # `pnpm deploy --prod` does not carry this one: the entry package lists it as an
  # *optional* dependency, and deploy leaves optional workspace packages behind.
  # flock.ts resolves the package's own `package.json` before loading the addon, so
  # the directory has to exist; take the manifest and metadata from the workspace
  # (the binary is built here, not shipped in the repository).
  if [ ! -f "$package_dir/package.json" ]; then
    local workspace_package="$root/native/system/packages/darwin-arm64"
    [ -f "$workspace_package/package.json" ] \
      || fail "native/system/packages/darwin-arm64 is missing from this checkout"
    say "the deploy left node-addon-system-darwin-arm64 out; taking its manifest from the workspace"
    mkdir -p "$package_dir"
    cp "$workspace_package/package.json" "$workspace_package/prebuilds.json" "$package_dir/"
    cp "$workspace_package/README.md" "$workspace_package/LICENSE" "$package_dir/" 2>/dev/null || true
  fi

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

# ── the profile resolver's native addon ───────────────────────────────────────
#
# `dsh-app-boot` calls node-addon-require-builtin while preparing the profile to
# reach Node's own ESM and CJS loaders. It is not on any tool path: without a
# binding the process throws before the server listens, which the app can only
# report as "连不上". The npm package ships desktop macOS binaries; this rebuilds
# the same sources against the iPhoneOS SDK and puts the result where the package
# already looks. tooling/ios/build-require-builtin.sh reproduces upstream's gyp
# conditions, so the backend/product/ABI tags the loader validates still match.
stage_require_builtin() {
  say "building node-addon-require-builtin for iOS"
  command -v xcrun >/dev/null || fail "xcrun is missing — this step needs Xcode"

  # Where pnpm put it: the deployed tree keeps optional packages either beside
  # the consumer or at the top level, and a symlink is a directory to `find -L`.
  local package_dir
  # `|| true`: under pipefail `head` closing the pipe is a failure, and an empty
  # answer is the diagnostic the next line gives.
  package_dir=$(find -L "$engine_dir/runtime/harness/node_modules" -maxdepth 5 -type d \
    -name 'node-addon-require-builtin-darwin-arm64' -print 2>/dev/null | head -n 1 || true)
  [ -n "$package_dir" ] && [ -f "$package_dir/prebuilds.json" ] || fail \
    "the deploy left node-addon-require-builtin-darwin-arm64 out; the keep-list in prune_foreign_platform_packages must cover it"

  "$root/tooling/ios/build-require-builtin.sh" iphoneos \
    "$package_dir/prebuilt/darwin-arm64-napi-v9.node" "$vendor_dir/include/node" \
    || fail "node-addon-require-builtin did not compile against the iPhoneOS SDK"

  printf 'prepare-engine: %s\n' "$package_dir/prebuilt/darwin-arm64-napi-v9.node"
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
  stage_require_builtin
elif [ "$run_harness" -eq 1 ]; then
  say "skipping the flock addon: Node's headers are not staged, so there is nothing to compile against"
fi
# Last, so that what this script stages is already in place: the iOS binaries are
# what the pruning rule keeps.
if [ "$run_harness" -eq 1 ]; then
  prune_non_ios_binaries "$engine_dir/runtime/harness"
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
