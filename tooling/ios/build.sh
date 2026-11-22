# Build the DPSK iOS app into an unsigned .ipa, or compile it for the simulator.
#
#   tooling/ios/build.sh iphoneos        <output-dir>   → <output-dir>/DPSK.ipa
#   tooling/ios/build.sh iphonesimulator <output-dir>   → compile check only
#
# macOS only: xcodegen, xcodebuild and zip are needed. The .ipa is UNSIGNED, so a
# signing tool (Sideloadly, AltStore, eSign) must sign it while installing. Which
# App the device gets is decided by `app/ios/project.yml`, never by this script.
set -eu

sdk="${1:?usage: build.sh <iphoneos|iphonesimulator> <output-dir>}"
out="${2:?usage: build.sh <iphoneos|iphonesimulator> <output-dir>}"

case "$sdk" in
  iphoneos | iphonesimulator) ;;
  *)
    echo "build.sh: unknown sdk '$sdk' (iphoneos or iphonesimulator)" >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "$0")/../.." && pwd)"
app="$root/app/ios"
work="$root/.dpsk-ios"

command -v xcodegen >/dev/null 2>&1 || {
  echo "build.sh: xcodegen is required (brew install xcodegen)" >&2
  exit 1
}

mkdir -p "$out"
cd "$app"

if [ "$sdk" = iphoneos ]; then
  # A device archive links Node and embeds it; without the staged runtime the
  # failure would be a link error far from its cause.
  [ -f Vendor/node/lib/libnode.dylib ] || {
    echo "build.sh: Vendor/node/lib/libnode.dylib is missing — run tooling/ios/prepare-engine.sh" >&2
    exit 1
  }
  [ -f Engine/runtime/harness/lib/bin.js ] || {
    echo "build.sh: Engine/runtime/harness is empty — run tooling/ios/prepare-engine.sh" >&2
    exit 1
  }
  spec=project.yml
else
  # The simulator has no arm64-iPhoneOS libnode to link, so this run is a compile
  # check of the Swift and ObjC sources: same spec minus the dependency block.
  mkdir -p "$work"
  sed '/# yaml-remove-start: node-runtime-dependency/,/# yaml-remove-end: node-runtime-dependency/d' \
    project.yml > "$work/project.simulator.yml"
  spec="$work/project.simulator.yml"
fi

xcodegen generate --spec "$spec"

# Every build carries its own version, and the minor number advances on every
# build: a build has to be identifiable from the installed app alone, and two
# builds must never answer to the same version. The patch number stays the commit
# count, which names the tree the build came from; the minor is what the last
# build used plus one, kept outside the tree so a rebuild in the same checkout
# still advances it.
#
# The counter lives at $DSH_IOS_BUILD_COUNTER, defaulting to
# .dpsk-ios/build-counter beside the build tree. A CI run that wants the count to
# keep moving across runs exports it from a cache; without one it starts at 1.
major=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([0-9][0-9]*\)\.[0-9][0-9]*\..*/\1/p' \
  project.yml | head -1)
major="${major:-0}"
patch_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)

counter_file="${DSH_IOS_BUILD_COUNTER:-$work/build-counter}"
mkdir -p "$(dirname "$counter_file")"
previous=0
if [ -f "$counter_file" ]; then
  previous=$(tr -cd '0-9' <"$counter_file")
  [ -n "$previous" ] || previous=0
fi
minor=$((previous + 1))
printf '%s\n' "$minor" >"$counter_file"

marketing_version="$major.$minor.$patch_number"
build_number="$minor"
echo "build.sh: version $marketing_version (build $build_number, previous minor $previous)"

if [ "$sdk" = iphonesimulator ]; then
  destination="generic/platform=iOS Simulator"
else
  destination="generic/platform=iOS"
fi

xcodebuild \
  -project DPSK.xcodeproj \
  -scheme DPSK \
  -configuration Release \
  -sdk "$sdk" \
  -destination "$destination" \
  -derivedDataPath "$work/DerivedData" \
  -archivePath "$work/DPSK-$sdk.xcarchive" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive

if [ "$sdk" = iphonesimulator ]; then
  echo "build.sh: simulator compile check passed ($work/DPSK-$sdk.xcarchive)"
  exit 0
fi

product="$work/DPSK-$sdk.xcarchive/Products/Applications/DPSK.app"
[ -d "$product" ] || {
  echo "build.sh: the archive carries no DPSK.app at $product" >&2
  exit 1
}

stage="$out/Payload"
rm -rf "${stage:?}" "$out/DPSK.ipa"
mkdir -p "$stage"
cp -R "$product" "$stage/DPSK.app"
# An .ipa is a zip of Payload/, and cp -R keeps the mode of every nested file.
(cd "$out" && zip -qry DPSK.ipa Payload)
rm -rf "${stage:?}"

echo "build.sh: wrote $out/DPSK.ipa (unsigned)"