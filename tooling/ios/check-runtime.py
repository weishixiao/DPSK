#!/usr/bin/env python3
"""Fail a build whose runtime cannot satisfy its own patch overlays.

The staged engine is a cached artifact, while app/ios/Engine/*.yml is copied
straight from the checkout. When the two drift -- a new patch row naming a
package or subpath the cached runtime predates -- the engine boots into
"plugin tree failed to load" and the app reports it as a crash.

Reads either layout:
  * dsh-Go style: Engine/runtime.zip (manifest.json + files/...)
  * DPSK style:   Engine/runtime/harness/ (a deployed node_modules tree)

and resolves every `name:` the overlays mount, including subpath exports and
pnpm's .pnpm store. Exit 1 listing the unresolved rows.

Usage: check-runtime.py --engine app/ios/Engine
"""
import argparse
import glob
import json
import os
import re
import sys
import zipfile

ROW_NAME = re.compile(r"^\s*(?:-\s*)?name:\s*['\"]?(@[^'\"\s]+|[a-z0-9][^'\"\s]*/?)['\"]?\s*$")
OVERLAYS = ("ios.patch.yml", "ios-preset.patch.yml")


def names_in(text):
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = ROW_NAME.match(line)
        if m:
            out.append(m.group(1))
    return out


def split_spec(spec):
    """'@scope/pkg/sub' -> ('@scope/pkg', 'sub'); 'pkg' -> ('pkg', None)."""
    parts = spec.split("/")
    take = 2 if spec.startswith("@") and len(parts) >= 2 else 1
    return "/".join(parts[:take]), ("/".join(parts[take:]) or None)


def export_target(pkg_json, sub):
    """Resolve `pkg/sub` under the default condition, including wildcards."""
    exports = pkg_json.get("exports")
    key = "." if sub is None else "./" + sub
    if exports is None:
        return key
    if isinstance(exports, str):
        return exports if key == "." else None
    if isinstance(exports, list):
        return next((item for item in exports if isinstance(item, str)), None)
    if key in exports:
        value = exports[key]
        if isinstance(value, str):
            return value
        if isinstance(value, dict):
            for cond in ("default", "import", "require"):
                if isinstance(value.get(cond), str):
                    return value[cond]
            return next((v for v in value.values() if isinstance(v, str)), None)
        return None
    for pattern, value in exports.items():
        if not pattern.endswith("*") or not key.startswith(pattern[:-1]):
            continue
        if isinstance(value, dict):
            value = value.get("default") or next((v for v in value.values() if isinstance(v, str)), None)
        if isinstance(value, str):
            return value.replace("*", key[len(pattern) - 1:])
    return None


class Runtime:
    """Zip layout or deployed tree; both answer "where is this package?"."""

    def __init__(self, engine):
        self.zip = None
        self.root = None
        self.names = set()
        zpath = os.path.join(engine, "runtime.zip")
        if os.path.isfile(zpath):
            self.zip = zipfile.ZipFile(zpath)
            self.prefix = "files/"
            self.names = set(self.zip.namelist())
        else:
            self.root = os.path.join(engine, "runtime", "harness")
            if not os.path.isdir(self.root):
                sys.exit(f"check-runtime: neither {zpath} nor {self.root} exists")

    def _member(self, rel):
        return "files/" + rel

    def has(self, rel):
        if self.zip is not None:
            return self._member(rel) in self.names
        return os.path.isfile(os.path.join(self.root, rel))

    def read(self, rel):
        if self.zip is not None:
            return self.zip.read(self._member(rel)).decode("utf-8")
        with open(os.path.join(self.root, rel), encoding="utf-8") as handle:
            return handle.read()

    def package(self, pkg):
        """(dir_rel, package.json dict) for pkg, preferring the top level."""
        candidates = [f"node_modules/{pkg}"]
        if self.zip is None:
            mangled = pkg.replace("/", "+")
            candidates += sorted(
                os.path.relpath(path, self.root).replace(os.sep, "/")
                for path in glob.glob(os.path.join(self.root, "node_modules", ".pnpm", f"{mangled}@*", "node_modules", pkg))
            )
        for directory in candidates:
            manifest = directory + "/package.json"
            if not self.has(manifest):
                continue
            try:
                return directory, json.loads(self.read(manifest))
            except json.JSONDecodeError:
                continue
        return None, None

    def close(self):
        if self.zip is not None:
            self.zip.close()


def declared_dependencies(manifest):
    """Names a package needs at run time, from both dependency kinds.

    `optionalDependencies` stay out: on a staged tree those are the platform
    prebuilds that are absent by design.
    """
    for key in ("dependencies", "peerDependencies"):
        for name in (manifest.get(key) or {}):
            yield name


def missing_closure(runtime):
    """First-party packages reachable from required rows whose deps do not resolve.

    Bounded on purpose: the closures are walked from the packages the overlays and
    the required rows name, not from every package in the store, so the report
    stays about what a boot actually touches.
    """
    seen_packages, seen_names, unresolved = set(), set(), []

    def visit(pkg):
        if pkg in seen_packages:
            return
        seen_packages.add(pkg)
        directory, manifest = runtime.package(pkg)
        if manifest is None:
            return
        for dependency in declared_dependencies(manifest):
            if dependency in seen_names:
                continue
            if not dependency.startswith("@deepseek-ai/"):
                continue
            seen_names.add(dependency)
            dep_dir, dep_manifest = runtime.package(dependency)
            if dep_manifest is None:
                unresolved.append(f"{pkg} imports {dependency}, which is not in the runtime")
                continue
            # Only first-party packages that ship JS are walked further.
            if dep_dir is not None:
                visit(dependency)

    roots = set()
    for overlay in OVERLAYS:
        path = os.path.join(runtime.root, overlay) if runtime.zip is None else None
        if path is None or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            for spec in names_in(handle.read()):
                if ":" in spec:
                    continue
                name, _ = split_spec(spec)
                if name.startswith("@deepseek-ai/"):
                    roots.add(name)
    # Start from the CLI itself: every required row is mounted from it.
    roots.add("@deepseek-ai/dsh")
    for root in sorted(roots):
        visit(root)
    return unresolved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    args = ap.parse_args()
    engine = args.engine.rstrip("/")
    runtime = Runtime(engine)

    problems, checked = [], 0
    for overlay in OVERLAYS:
        path = os.path.join(engine, overlay)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            specs = names_in(handle.read())
        for spec in specs:
            # `cordis:group` is a composition marker, not a package specifier.
            if ":" in spec:
                continue
            pkg, sub = split_spec(spec)
            directory, pkg_json = runtime.package(pkg)
            if pkg_json is None:
                problems.append(f"{overlay}: {spec}: package {pkg} is not in the runtime")
                continue
            target = export_target(pkg_json, sub)
            if target is None:
                problems.append(f"{overlay}: {spec}: {directory}/package.json has no export for this subpath")
                continue
            if target.startswith("./"):
                target = target[2:]
            if not runtime.has(f"{directory}/{target}"):
                problems.append(f"{overlay}: {spec}: export {target} is absent from {directory}")
                continue
            checked += 1

    entries = ["runtime/ohos/preload.mjs", "node_modules/@deepseek-ai/dsh/lib/bin.js"]
    if runtime.zip is not None:
        entries.append("node_modules/@dsh-go/ohos-native/index.cjs")
    else:
        entries = ["lib/bin.js"]
    for entry in entries:
        if not runtime.has(entry):
            problems.append(f"fixed entry {entry} is missing")

    # The overlay rows only name JS plugins. These two addons are loaded by
    # package resolution at boot, and a missing one is exactly as fatal:
    # `dsh-app-boot` cannot reach Node's loaders without require-builtin, and the
    # session store needs flock. Check the file the package would map, not the
    # package name alone.
    if runtime.zip is None:
        for pkg, rel in (
            ("node-addon-require-builtin-darwin-arm64", "prebuilt/darwin-arm64-napi-v9.node"),
            ("@deepseek-ai/node-addon-system-darwin-arm64", "bin/system.node"),
        ):
            directory, manifest = runtime.package(pkg)
            if manifest is None:
                problems.append(f"native addon {pkg} is not in the runtime")
            elif not runtime.has(f"{directory}/{rel}"):
                problems.append(f"native addon {pkg} has no {rel}")

    # A row can name a package that is present while the packages *it* imports
    # are not. That is the failure a device actually showed: the overlay resolved,
    # the listener bound, and 250 ms later the run unwound because a plugin in a
    # required row's closure could not import `@deepseek-ai/dsh-session`. The
    # overlay check above cannot see it -- the row names `dsh-web-app`, not the
    # peer three hops down.
    #
    # So walk the real dependency closure of every first-party package the runtime
    # carries, and require each `@deepseek-ai/*` name it declares to resolve. Peers
    # count: a staged copy of a package has no `node_modules` of its own, so a peer
    # it imports is only reachable if the tree root has it.
    if runtime.zip is None:
        problems.extend(missing_closure(runtime))

    runtime.close()
    if problems:
        print("check-runtime: the runtime cannot serve these overlays:", file=sys.stderr)
        for line in problems:
            print("  " + line, file=sys.stderr)
        sys.exit(1)
    print(f"check-runtime: {checked} overlay rows resolve inside {engine}")


if __name__ == "__main__":
    main()
