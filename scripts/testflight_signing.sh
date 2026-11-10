#!/usr/bin/env bash
# Secrets are read only from the job environment; never enable shell tracing.
set -euo pipefail
umask 077
SIGN_DIR="${RUNNER_TEMP:?}/wanbuddy-testflight"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
PROFILE_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"

case "${1:-}" in
  setup)
    for name in BUILD_CERTIFICATE_BASE64 P12_PASSWORD BUILD_PROVISION_PROFILE_BASE64 APPLE_TEAM_ID; do
      if [ -z "${!name:-}" ]; then
        echo "Required signing setting is missing: $name" >&2
        exit 1
      fi
    done
    mkdir -p "$SIGN_DIR"
    printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$SIGN_DIR/distribution.p12"
    printf '%s' "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$SIGN_DIR/profile.mobileprovision"
    security cms -D -i "$SIGN_DIR/profile.mobileprovision" > "$SIGN_DIR/profile.plist"
    KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
    echo "::add-mask::$KEYCHAIN_PASSWORD"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 7200 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    # security requires password arguments. Never print commands or command output.
    security import "$SIGN_DIR/distribution.p12" -P "$P12_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
    security list-keychains -d user > "$SIGN_DIR/original-keychains.txt"
    # Keep existing runner keychains in the search list (Apple intermediate certs).
    python3 - "$KEYCHAIN" "$SIGN_DIR/original-keychains.txt" <<'PY'
import pathlib, shlex, subprocess, sys
original = shlex.split(pathlib.Path(sys.argv[2]).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', sys.argv[1], *original], check=True)
PY
    security find-identity -v -p codesigning "$KEYCHAIN" > "$SIGN_DIR/identities.txt"
    python3 scripts/testflight_validate.py profile \
      --profile "$SIGN_DIR/profile.plist" --identities "$SIGN_DIR/identities.txt" \
      --team "$APPLE_TEAM_ID" --build "$BUILD_NUMBER" \
      --export-options "$SIGN_DIR/ExportOptions.plist" > "$SIGN_DIR/profile-selection.txt"
    PROFILE_UUID=$(sed -n '1p' "$SIGN_DIR/profile-selection.txt")
    PROFILE_DEST="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
    mkdir -p "$PROFILE_DIR"
    cp "$SIGN_DIR/profile.mobileprovision" "$PROFILE_DEST"
    chmod 600 "$PROFILE_DEST"
    rm -f "$SIGN_DIR/distribution.p12"
    ;;
  cleanup)
    if [ -f "$SIGN_DIR/original-keychains.txt" ]; then
      python3 - "$SIGN_DIR/original-keychains.txt" <<'PY'
import pathlib, shlex, subprocess, sys
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *shlex.split(pathlib.Path(sys.argv[1]).read_text())], check=False)
PY
    fi
    security delete-keychain "$KEYCHAIN" > /dev/null 2>&1 || true
    if [ -f "$SIGN_DIR/profile-selection.txt" ]; then
      PROFILE_UUID=$(sed -n '1p' "$SIGN_DIR/profile-selection.txt")
      if [[ "$PROFILE_UUID" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
        rm -f "$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
      fi
    fi
    rm -rf "$SIGN_DIR"
    ;;
  *) echo 'Usage: testflight_signing.sh setup|cleanup' >&2; exit 1 ;;
esac
