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

# Every build carries its own version: the patch number is the number of commits
# on the branch and the build number is the same count, so a build names the tree
# it came from and two builds of one commit are the same build. The major/minor
# line stays in project.yml — this reads it rather than keeping a second copy —
# and a tree without git (a source tarball) falls back to build 1.
version_line=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' \
  project.yml | head -1)
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
marketing_version="${version_line:-0.1}.$build_number"
echo "build.sh: version $marketing_version ($build_number)"

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