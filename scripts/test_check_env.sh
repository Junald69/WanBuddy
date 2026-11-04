#!/usr/bin/env bash
# Exercises check_env.sh against the committed xcconfigs and synthetic fixtures.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="${ROOT}/scripts/check_env.sh"

pass() {
  echo "PASS $1"
}

expect_ok() {
  name=$1
  shift
  if "${CHECK}" "$@" >"${TMP}/out" 2>"${TMP}/err"; then
    pass "${name}"
  else
    echo "FAIL ${name}: expected exit 0" >&2
    cat "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
}

expect_fail() {
  name=$1
  shift
  if "${CHECK}" "$@" >"${TMP}/out" 2>"${TMP}/err"; then
    echo "FAIL ${name}: expected non-zero exit" >&2
    cat "${TMP}/out" >&2
    exit 1
  fi
  if ! grep -q "check_env: FAIL" "${TMP}/out"; then
    echo "FAIL ${name}: missing check_env: FAIL marker" >&2
    cat "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  pass "${name}"
}

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

expect_ok "Debug xcconfig" --configuration Debug --xcconfig "${ROOT}/ios/Config/Debug.xcconfig"
expect_ok "Beta xcconfig" --configuration Beta --xcconfig "${ROOT}/ios/Config/Beta.xcconfig"
expect_fail "empty Release xcconfig" --configuration Release --xcconfig "${ROOT}/ios/Config/Release.xcconfig"

cat > "${TMP}/Common.xcconfig" <<'EOF'
PRODUCT_BUNDLE_IDENTIFIER_BASE = com.junald69.wanbuddy
EOF

write_release() {
  cat > "${TMP}/Release.xcconfig" <<EOF
#include "Common.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = \$(PRODUCT_BUNDLE_IDENTIFIER_BASE)
WANBUDDY_CONFIGURATION = release
SUPABASE_PROJECT_REF = $1
SUPABASE_URL = $2
SUPABASE_PUBLISHABLE_KEY = $3
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $4
EOF
}

write_release "abcdefghijklmnopqrst" 'https:/$()/abcdefghijklmnopqrst.supabase.co' "sb_publishable_example" "RELEASE"
expect_ok "synthetic valid Release" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "nlvjvmymeuvbxlzikpjx" 'https:/$()/nlvjvmymeuvbxlzikpjx.supabase.co' "sb_publishable_example" "RELEASE"
expect_fail "Release using Development ref" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "abcdefghijklmnopqrst" 'https:/$()/wrongrefwrongrefwrong.supabase.co' "sb_publishable_example" "RELEASE"
expect_fail "Release URL mismatch" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "abcdefghijklmnopqrst" 'https:/$()/abcdefghijklmnopqrst.supabase.co' "eyJhbGciOiJIUzI1NiJ9.x.y" "RELEASE"
expect_fail "Release legacy JWT key" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "abcdefghijklmnopqrst" 'https:/$()/abcdefghijklmnopqrst.supabase.co' "sb_secret_hidden" "RELEASE"
expect_fail "Release secret key" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "abcdefghijklmnopqrst" 'https:/$()/abcdefghijklmnopqrst.supabase.co' "service_role_key_value" "RELEASE"
expect_fail "Release service_role key" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "short" 'https:/$()/short.supabase.co' "sb_publishable_example" "RELEASE"
expect_fail "Release short ref" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

write_release "abcdefghijklmnopqrst" 'https:/$()/abcdefghijklmnopqrst.supabase.co' "sb_publishable_example" "RELEASE DEV_LOGIN"
expect_fail "Release defines DEV_LOGIN" --configuration Release --xcconfig "${TMP}/Release.xcconfig"

cat > "${TMP}/Debug.xcconfig" <<'EOF'
#include "Common.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE)
SUPABASE_PROJECT_REF = nlvjvmymeuvbxlzikpjx
SUPABASE_URL = https:/$()/nlvjvmymeuvbxlzikpjx.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_rhef8TN72C7vSi6itEHl_g__VXiEkhN
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG DEV_LOGIN
EOF
expect_fail "Debug bundle id is not .dev" --configuration Debug --xcconfig "${TMP}/Debug.xcconfig"

cat > "${TMP}/Debug.xcconfig" <<'EOF'
#include "Common.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE).dev
SUPABASE_PROJECT_REF = abcdefghijklmnopqrst
SUPABASE_URL = https:/$()/abcdefghijklmnopqrst.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_example
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG DEV_LOGIN
EOF
expect_fail "Debug ref is not Development" --configuration Debug --xcconfig "${TMP}/Debug.xcconfig"

cat > "${TMP}/Beta.xcconfig" <<'EOF'
#include "Common.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE).beta
SUPABASE_PROJECT_REF = nlvjvmymeuvbxlzikpjx
SUPABASE_URL = https:/$()/nlvjvmymeuvbxlzikpjx.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_rhef8TN72C7vSi6itEHl_g__VXiEkhN
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG DEV_LOGIN
EOF
expect_fail "Beta defines DEBUG" --configuration Beta --xcconfig "${TMP}/Beta.xcconfig"

printf '%s\n' \
  '#include "Common.xcconfig"' \
  'PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE)' \
  'SUPABASE_PROJECT_REF = abcdefghijklmnopqrst' \
  'SUPABASE_URL = https:/$()/abcdefghijklmnopqrst.supabase.co' \
  'SUPABASE_PUBLISHABLE_KEY = sb_publishable_example' \
  "$(printf 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE\tDEV_LOGIN')" \
  > "${TMP}/ReleaseTab.xcconfig"
expect_fail "xcconfig Release tab-separated DEV_LOGIN" --configuration Release --xcconfig "${TMP}/ReleaseTab.xcconfig"

cat > "${TMP}/ReleaseFlags.xcconfig" <<'EOF'
#include "Common.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = $(PRODUCT_BUNDLE_IDENTIFIER_BASE)
SUPABASE_PROJECT_REF = abcdefghijklmnopqrst
SUPABASE_URL = https:/$()/abcdefghijklmnopqrst.supabase.co
SUPABASE_PUBLISHABLE_KEY = sb_publishable_example
SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE
OTHER_SWIFT_FLAGS = -DDEV_LOGIN
EOF
expect_fail "xcconfig Release -DDEV_LOGIN" --configuration Release --xcconfig "${TMP}/ReleaseFlags.xcconfig"

expect_ok_env() {
  name=$1
  shift
  if env -i PATH="${PATH}" "$@" bash "${CHECK}" >"${TMP}/out" 2>"${TMP}/err"; then
    pass "${name}"
  else
    echo "FAIL ${name}: expected exit 0" >&2
    cat "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
}

expect_fail_env() {
  name=$1
  shift
  if env -i PATH="${PATH}" "$@" bash "${CHECK}" >"${TMP}/out" 2>"${TMP}/err"; then
    echo "FAIL ${name}: expected non-zero exit" >&2
    cat "${TMP}/out" >&2
    exit 1
  fi
  if ! grep -q "check_env: FAIL" "${TMP}/out"; then
    echo "FAIL ${name}: missing check_env: FAIL marker" >&2
    cat "${TMP}/out" "${TMP}/err" >&2
    exit 1
  fi
  pass "${name}"
}

DEV_REF_VALUE="nlvjvmymeuvbxlzikpjx"
DEV_URL_VALUE="https://${DEV_REF_VALUE}.supabase.co"
DEV_KEY_VALUE="sb_publishable_rhef8TN72C7vSi6itEHl_g__VXiEkhN"
BASE_VALUE="com.junald69.wanbuddy"

expect_fail_env "env empty Release" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE

expect_fail_env "env Release with Development ref" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE \
  SUPABASE_PROJECT_REF="${DEV_REF_VALUE}" \
  SUPABASE_URL="${DEV_URL_VALUE}" \
  SUPABASE_PUBLISHABLE_KEY="${DEV_KEY_VALUE}"

expect_ok_env "env Debug" \
  CONFIGURATION=Debug \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}.dev" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG DEV_LOGIN" \
  SUPABASE_PROJECT_REF="${DEV_REF_VALUE}" \
  SUPABASE_URL="${DEV_URL_VALUE}" \
  SUPABASE_PUBLISHABLE_KEY="${DEV_KEY_VALUE}"

expect_ok_env "env Beta" \
  CONFIGURATION=Beta \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}.beta" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="BETA DEV_LOGIN" \
  SUPABASE_PROJECT_REF="${DEV_REF_VALUE}" \
  SUPABASE_URL="${DEV_URL_VALUE}" \
  SUPABASE_PUBLISHABLE_KEY="${DEV_KEY_VALUE}"

expect_ok_env "env valid Release" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE \
  SUPABASE_PROJECT_REF=abcdefghijklmnopqrst \
  SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_example

expect_fail_env "env Release OTHER_SWIFT_FLAGS -DDEV_LOGIN" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE \
  OTHER_SWIFT_FLAGS=-DDEV_LOGIN \
  SUPABASE_PROJECT_REF=abcdefghijklmnopqrst \
  SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_example

expect_fail_env "env Release OTHER_SWIFT_FLAGS -D DEBUG" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE \
  OTHER_SWIFT_FLAGS="-D DEBUG" \
  SUPABASE_PROJECT_REF=abcdefghijklmnopqrst \
  SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_example

expect_fail_env "env Release tab-separated DEV_LOGIN" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(printf 'RELEASE\tDEV_LOGIN')" \
  SUPABASE_PROJECT_REF=abcdefghijklmnopqrst \
  SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_example

expect_fail_env "env Release tab before -DDEV_LOGIN" \
  CONFIGURATION=Release \
  PRODUCT_BUNDLE_IDENTIFIER="${BASE_VALUE}" \
  PRODUCT_BUNDLE_IDENTIFIER_BASE="${BASE_VALUE}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=RELEASE \
  OTHER_SWIFT_FLAGS="$(printf '\t-DDEV_LOGIN')" \
  SUPABASE_PROJECT_REF=abcdefghijklmnopqrst \
  SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co \
  SUPABASE_PUBLISHABLE_KEY=sb_publishable_example

echo "check_env tests passed"
