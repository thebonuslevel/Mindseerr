#!/bin/bash
# Builds Mindseerr.ipa for Apple TV. Run on a Mac with Xcode installed.
#
#   ./make-ipa.sh               Signed with your Apple developer team. Installs on Apple TVs
#                               registered to that team (yours, once it's paired with Xcode).
#   TEAM=ABCDE12345 ./make-ipa.sh
#                               Same, with the team ID given directly.
#   ./make-ipa.sh --unsigned    Unsigned IPA, for signing later with another tool.
#
# The finished IPA is written next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP=Mindseerr
PROJECT="$APP.xcodeproj"
BUILD="build"

fail() { echo "✗ $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "Xcode isn't installed. Install it from the Mac App Store, open it once, then run this again."

if [ ! -d "$PROJECT" ]; then
  command -v xcodegen >/dev/null || fail "XcodeGen isn't installed. Run: brew install xcodegen"
  echo "→ Generating $PROJECT"
  xcodegen generate
fi

mkdir -p "$BUILD"

# ---------------------------------------------------------------- unsigned
if [ "${1:-}" = "--unsigned" ]; then
  echo "→ Building $APP (unsigned, Release)"
  xcodebuild -project "$PROJECT" -scheme "$APP" -configuration Release \
    -sdk appletvos -destination 'generic/platform=tvOS' \
    -derivedDataPath "$BUILD/derived" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)" || true

  PRODUCT="$BUILD/derived/Build/Products/Release-appletvos/$APP.app"
  [ -d "$PRODUCT" ] || fail "The build failed. Open $PROJECT in Xcode and press ⌘B to see the errors."

  rm -rf "$BUILD/Payload" && mkdir -p "$BUILD/Payload"
  cp -R "$PRODUCT" "$BUILD/Payload/"
  rm -f "$APP-unsigned.ipa"
  (cd "$BUILD" && zip -qry "../$APP-unsigned.ipa" Payload)
  echo "✓ Done: $(pwd)/$APP-unsigned.ipa"
  exit 0
fi

# ---------------------------------------------------------------- signed
TEAM="${TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(xcodebuild -project "$PROJECT" -scheme "$APP" -showBuildSettings 2>/dev/null \
         | awk -F' = ' '/ DEVELOPMENT_TEAM = /{print $2; exit}')
fi
[ -n "$TEAM" ] || fail "No signing team is set. Open $PROJECT in Xcode, choose your Team under
  Signing & Capabilities, then run this again. Or run: TEAM=<your team ID> ./make-ipa.sh
  (Your team ID is under Xcode → Settings → Accounts, or developer.apple.com → Membership.)"

echo "→ Archiving $APP for Apple TV (team $TEAM)"
rm -rf "$BUILD/$APP.xcarchive"
xcodebuild -project "$PROJECT" -scheme "$APP" -configuration Release \
  -destination 'generic/platform=tvOS' \
  -archivePath "$BUILD/$APP.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$BUILD/$APP.xcarchive" ] || fail "Archiving failed. Open $PROJECT in Xcode and choose Product → Archive to see the errors."

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

echo "→ Exporting IPA"
rm -rf "$BUILD/export"
xcodebuild -exportArchive \
  -archivePath "$BUILD/$APP.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true

[ -f "$BUILD/export/$APP.ipa" ] || fail "Exporting failed. Make sure your Apple TV is paired in Xcode (Window → Devices and Simulators) so it's registered to your team, then try again. Or run: ./make-ipa.sh --unsigned"
cp "$BUILD/export/$APP.ipa" "./$APP.ipa"
echo "✓ Done: $(pwd)/$APP.ipa"
echo "  To install: Xcode → Window → Devices and Simulators → your Apple TV → + under Installed Apps → pick $APP.ipa"
