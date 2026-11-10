#!/usr/bin/env bash
set -euo pipefail
umask 077
SIGN_DIR="${RUNNER_TEMP:?}/wanbuddy-testflight"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
PROFILE_UUID=$(sed -n '1p' "$SIGN_DIR/profile-selection.txt")
IDENTITY=$(sed -n '2p' "$SIGN_DIR/profile-selection.txt")
# These command-line overrides apply only to this job, not to normal builds.
settings=(
  -project ios/WanBuddy.xcodeproj -scheme WanBuddy -configuration Beta
  -destination 'generic/platform=iOS' -sdk iphoneos
  -derivedDataPath "$SIGN_DIR/DerivedData"
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual
  "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=${APPLE_TEAM_ID:?}"
  "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_UUID"
  "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:?}"
  "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN"
)
validate=(--profile "$SIGN_DIR/profile.plist" --identities "$SIGN_DIR/identities.txt"
          --team "$APPLE_TEAM_ID" --build "$BUILD_NUMBER")
xcodebuild "${settings[@]}" -showBuildSettings -json > "$SIGN_DIR/settings.json"
python3 scripts/testflight_validate.py settings "${validate[@]}" --settings "$SIGN_DIR/settings.json"
xcodebuild "${settings[@]}" -archivePath "$SIGN_DIR/WanBuddy.xcarchive" archive
xcodebuild -exportArchive -archivePath "$SIGN_DIR/WanBuddy.xcarchive" \
  -exportOptionsPlist "$SIGN_DIR/ExportOptions.plist" -exportPath "$SIGN_DIR/Export"
IPA="$SIGN_DIR/Export/WanBuddy.ipa"
test -f "$IPA"
mkdir -p "$SIGN_DIR/Unpacked"
unzip -q "$IPA" -d "$SIGN_DIR/Unpacked"
APP="$SIGN_DIR/Unpacked/Payload/WanBuddy.app"
codesign --verify --deep --strict "$APP"
xcrun lipo -verify_arch arm64 "$APP/WanBuddy"
codesign -d --entitlements :- "$APP" > "$SIGN_DIR/entitlements.plist" 2> /dev/null
codesign -d --extract-certificates "$SIGN_DIR/signer-" "$APP" 2> /dev/null
security cms -D -i "$APP/embedded.mobileprovision" > "$SIGN_DIR/exported-profile.plist"
python3 scripts/testflight_validate.py ipa \
  --profile "$SIGN_DIR/exported-profile.plist" --identities "$SIGN_DIR/identities.txt" \
  --team "$APPLE_TEAM_ID" --build "$BUILD_NUMBER" \
  --app "$APP" --entitlements "$SIGN_DIR/entitlements.plist" \
  --certificate "$SIGN_DIR/signer-0"
# Publish no IPA or credentials as artifacts. Only non-secret build metadata.
mkdir -p "$RUNNER_TEMP/wanbuddy-testflight-report"
python3 - "$IPA" "$RUNNER_TEMP/wanbuddy-testflight-report/build.json" <<'PY'
import hashlib, json, os, pathlib, sys
ipa = pathlib.Path(sys.argv[1])
report = {'commit': os.environ['GITHUB_SHA'], 'configuration': 'Beta',
          'bundle_id': 'com.junald69.wanbuddy.beta', 'backend': 'Development',
          'version': '0.2.0', 'build': os.environ['BUILD_NUMBER'],
          'ipa_sha256': hashlib.sha256(ipa.read_bytes()).hexdigest()}
pathlib.Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n')
PY
