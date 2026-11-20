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
xcodegen generate --spec project.yml

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