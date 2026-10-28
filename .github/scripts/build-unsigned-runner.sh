#!/usr/bin/env bash
set -euo pipefail
SRC="$1"; OUT="$2"; MODE="$3"; EXPECTED="$4"; IDEVICE_ZIP="$5"; EVIDENCE="$6"
cd "$SRC"
test "$(git rev-parse HEAD)" = "$EXPECTED"
mkdir -p "$(dirname "$EVIDENCE")"
{
  echo "mode=$MODE"
  echo "source_commit=$(git rev-parse HEAD)"
  echo "source_tree=$(git rev-parse HEAD^{tree})"
  sw_vers
  xcodebuild -version
  xcode-select -p
  xcodegen --version
} > "$EVIDENCE"
export IDEVICE_ZIP
bash Scripts/fetch-idevice.sh
xcodegen generate --quiet
bash Scripts/stamp-build.sh
rm -rf build
xcodebuild build-for-testing   -project iCTRL.xcodeproj   -derivedDataPath build   -scheme iCTRL   -destination 'generic/platform=iOS'   ARCHS=arm64   CODE_SIGNING_ALLOWED=NO   CODE_SIGNING_REQUIRED=NO   CODE_SIGN_IDENTITY=''   DEVELOPMENT_TEAM=''   2>&1 | tee "${EVIDENCE%.txt}-xcodebuild.log"
BD=build/Build/Products/Debug-iphoneos
APP="$BD/iCTRLUITests-Runner.app"
BIN="$APP/iCTRLUITests-Runner"
XCTEST="$APP/PlugIns/iCTRLUITests.xctest"
TESTBIN="$XCTEST/iCTRLUITests"
test -d "$APP"; test -f "$BIN"; test -d "$XCTEST"; test -f "$TESTBIN"
PB=/usr/libexec/PlistBuddy
rm -f "$APP"/AppIcon*.png
cp Config/RunnerIcon/*.png "$APP/"
"$PB" -c 'Delete :CFBundleIcons' "$APP/Info.plist" 2>/dev/null || true
"$PB" -c 'Delete :CFBundleIcons~ipad' "$APP/Info.plist" 2>/dev/null || true
"$PB" -c 'Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array' "$APP/Info.plist"
i=0; for n in AppIcon20x20 AppIcon29x29 AppIcon40x40 AppIcon60x60; do "$PB" -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:$i string $n" "$APP/Info.plist"; i=$((i+1)); done
"$PB" -c 'Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array' "$APP/Info.plist"
i=0; for n in AppIcon20x20 AppIcon29x29 AppIcon40x40 AppIcon76x76 AppIcon83.5x83.5; do "$PB" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:$i string $n" "$APP/Info.plist"; i=$((i+1)); done
rm -rf "$APP/Frameworks/XCTAutomationSupport.framework" "$APP/Frameworks/XCTest.framework" "$APP/Frameworks/XCTestCore.framework" "$APP/Frameworks/XCTestSupport.framework" "$APP/Frameworks/XCUIAutomation.framework" "$APP/Frameworks/XCUnit.framework" "$APP/Frameworks/Testing.framework"
rm -f "$APP/Frameworks/libXCTestSwiftSupport.dylib"
rmdir "$APP/Frameworks" 2>/dev/null || true
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$APP/Frameworks"
xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$SDK" -mios-version-min=16.0 -install_name '@rpath/libXCTCompatShim.dylib' -framework Foundation -o "$APP/Frameworks/libXCTCompatShim.dylib" iCTRLCompat/XCTCompatShim.m
if ! otool -L "$BIN" | grep -q libXCTCompatShim; then
  T="$BIN.patching"; cp "$BIN" "$T"
  python3 Scripts/insert-dylib.py "$T" '@rpath/libXCTCompatShim.dylib'
  O="$(python3 Scripts/dylib-ordinal.py "$T" libXCTCompatShim)"
  python3 Scripts/retarget-bind-ordinal.py "$T" '_OBJC_CLASS_$$_XCTCommandLineToolHelper' "$O"
  python3 Scripts/retarget-undef-symbol.py "$T" '_OBJC_CLASS_$$_XCTCommandLineToolHelper' libXCTCompatShim
  mv "$T" "$BIN"
fi
find "$APP" -name '*.dSYM' -exec rm -rf {} + 2>/dev/null || true
"$PB" -c 'Delete :CFBundleURLTypes' "$APP/Info.plist" 2>/dev/null || true
"$PB" -c 'Add :CFBundleURLTypes array' "$APP/Info.plist"
"$PB" -c 'Add :CFBundleURLTypes:0 dict' "$APP/Info.plist"
"$PB" -c 'Add :CFBundleURLTypes:0:CFBundleURLName string com.openminis.ictrl' "$APP/Info.plist"
"$PB" -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$APP/Info.plist"
"$PB" -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ictrl' "$APP/Info.plist"
"$PB" -c 'Delete :NSBonjourServices' "$APP/Info.plist" 2>/dev/null || true
"$PB" -c 'Add :NSBonjourServices array' "$APP/Info.plist"
"$PB" -c 'Add :NSBonjourServices:0 string _ictrl._tcp' "$APP/Info.plist"
RID="$("$PB" -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
"$PB" -c "Set :CFBundleIdentifier $RID" "$XCTEST/Info.plist"
find "$APP" -name embedded.mobileprovision -delete
codesign --force --timestamp=none --sign - "$APP/Frameworks/libXCTCompatShim.dylib"
codesign --force --timestamp=none --sign - "$XCTEST"
codesign --force --timestamp=none --sign - "$APP"
codesign --verify --deep --strict "$APP"
! find "$APP" -name '*.mobileprovision' | grep -q .
if [[ "$MODE" == baseline ]]; then
  ! strings "$TESTBIN" | grep -Fq xctest_overlay_experiment
  echo "experiment_string_present=NO" >> "$EVIDENCE"
else
  strings "$TESTBIN" | grep -F xctest_overlay_experiment >/dev/null
  strings "$TESTBIN" | grep -F finishInitializationForUIAutomation >/dev/null
  echo "experiment_string_present=YES" >> "$EVIDENCE"
  echo "finish_selector_string_present=YES" >> "$EVIDENCE"
fi
ST="$(mktemp -d)"; mkdir -p "$ST/Payload"; cp -R "$APP" "$ST/Payload/"
(cd "$ST" && zip -qry "$GITHUB_WORKSPACE/$OUT" Payload)
rm -rf "$ST"
{
  echo "output=$OUT"
  shasum -a 256 "$GITHUB_WORKSPACE/$OUT"
  echo "runner_bundle_id=$RID"
  echo "provisioning_profile_present=NO"
  echo "signature=AD_HOC_ONLY"
} >> "$EVIDENCE"
