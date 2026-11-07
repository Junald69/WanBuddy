#!/usr/bin/env bash
# Fail the build when a configuration points at the wrong Supabase project.
# An empty Production configuration fails. Development is never substituted.
set -eu

DEV_REF="nlvjvmymeuvbxlzikpjx"
KEY_PREFIX="sb_publishable_"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BLOCKLIST="${SCRIPT_DIR}/../ios/Config/production_refs.blocklist"

KV=""
FAILURES=""

cleanup() {
  if [ -n "${KV}" ] && [ -d "${KV}" ]; then
    rm -rf "${KV}"
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: check_env.sh --configuration Debug|Beta|Release --xcconfig path" >&2
  echo "       check_env.sh    # Xcode run-script phase; reads build settings" >&2
}

fail() {
  FAILURES="${FAILURES}
check_env: FAIL $1"
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

kv_set() {
  printf '%s' "$2" > "${KV}/$1"
}

kv_get() {
  if [ -f "${KV}/$1" ]; then
    cat "${KV}/$1"
  fi
}

expand_value() {
  rest=$1
  output=""
  while true; do
    case "${rest}" in
      *'$('*) ;;
      *) break ;;
    esac
    pre=${rest%%'$('*}
    rest=${rest#*'$('}
    name=${rest%%')'*}
    case "${rest}" in
      *')'*) rest=${rest#*')'} ;;
      *) rest="" ;;
    esac
    repl=""
    if [ -n "${name}" ]; then
      repl=$(kv_get "${name}")
    fi
    output="${output}${pre}${repl}"
  done
  printf '%s' "${output}${rest}"
}

load_xcconfig() {
  file=$1
  depth=$2
  if [ "${depth}" -gt 8 ]; then
    fail "xcconfig include is too deep: ${file}"
    return
  fi
  if [ ! -f "${file}" ]; then
    fail "xcconfig not found: ${file}"
    return
  fi
  dir=$(CDPATH= cd -- "$(dirname -- "${file}")" && pwd)
  while IFS= read -r line || [ -n "${line}" ]; do
    line=${line%$'\r'}
    case "${line}" in
      ''|[[:space:]]*)
        stripped=$(trim "${line}")
        ;;
      *)
        stripped=${line}
        ;;
    esac
    case "${stripped}" in
      ''|'//'*) continue ;;
    esac
    case "${stripped}" in
      '#include '*|'#include"'*)
        inc=$(printf '%s' "${stripped}" | sed -n 's/.*["<]\([^">]*\)[">].*/\1/p')
        if [ -z "${inc}" ]; then
          fail "unreadable include in ${file}"
          continue
        fi
        load_xcconfig "${dir}/${inc}" $((depth + 1))
        continue
        ;;
    esac
    case "${stripped}" in
      *'//'*) stripped=${stripped%%//*} ;;
    esac
    case "${stripped}" in
      *=*) ;;
      *) continue ;;
    esac
    key=$(printf '%s' "${stripped}" | sed 's/=.*//' | sed 's/[[:space:]]*$//')
    value=$(printf '%s' "${stripped}" | sed 's/^[^=]*=//')
    value=$(trim "${value}")
    value=$(expand_value "${value}")
    kv_set "${key}" "${value}"
  done < "${file}"
}

normalize_ws() {
  printf '%s' "$1" | tr '[:space:]' ' ' | sed 's/  */ /g;s/^ //;s/ $//'
}

has_token() {
  haystack=" $(normalize_ws "$1") "
  needle=" $2 "
  case "${haystack}" in
    *"${needle}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when OTHER_SWIFT_FLAGS passes -DNAME. Tabs, "-D NAME", and quote
# wrapping ("-DNAME", -D"NAME", and the same with single quotes) all count.
has_swift_define() {
  text=$(normalize_ws "$1" | tr -d "\"'" | sed 's/-D /-D/g')
  name=$2
  for token in ${text}; do
    case "${token}" in
      -D"${name}"|-D"${name}"=*) return 0 ;;
    esac
  done
  return 1
}

ref_is_blocked() {
  if [ ! -f "${BLOCKLIST}" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    line=$(trim "${line}")
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    if [ "${line}" = "$1" ]; then
      return 0
    fi
  done < "${BLOCKLIST}"
  return 1
}

CONFIG_NAME=""
XCCONFIG_PATH=""

if [ $# -eq 0 ]; then
  if [ -z "${CONFIGURATION:-}" ]; then
    usage
    exit 2
  fi
  CONFIG_NAME=${CONFIGURATION}
  URL=$(trim "${SUPABASE_URL:-}")
  KEY=$(trim "${SUPABASE_PUBLISHABLE_KEY:-}")
  REF=$(trim "${SUPABASE_PROJECT_REF:-}")
  BUNDLE_ID=$(trim "${PRODUCT_BUNDLE_IDENTIFIER:-}")
  BASE=$(trim "${PRODUCT_BUNDLE_IDENTIFIER_BASE:-}")
  FLAGS="${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-}"
  OTHER_FLAGS="${OTHER_SWIFT_FLAGS:-}"
else
  while [ $# -gt 0 ]; do
    case "$1" in
      --configuration)
        CONFIG_NAME=${2:-}
        shift 2
        ;;
      --xcconfig)
        XCCONFIG_PATH=${2:-}
        shift 2
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  done
  if [ -z "${CONFIG_NAME}" ] || [ -z "${XCCONFIG_PATH}" ]; then
    usage
    exit 2
  fi
  KV=$(mktemp -d)
  load_xcconfig "${XCCONFIG_PATH}" 0
  URL=$(trim "$(kv_get SUPABASE_URL)")
  KEY=$(trim "$(kv_get SUPABASE_PUBLISHABLE_KEY)")
  REF=$(trim "$(kv_get SUPABASE_PROJECT_REF)")
  BUNDLE_ID=$(trim "$(kv_get PRODUCT_BUNDLE_IDENTIFIER)")
  BASE=$(trim "$(kv_get PRODUCT_BUNDLE_IDENTIFIER_BASE)")
  FLAGS="$(kv_get SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
  OTHER_FLAGS="$(kv_get OTHER_SWIFT_FLAGS)"
fi

FLAGS=$(normalize_ws "${FLAGS}")
OTHER_FLAGS=$(normalize_ws "${OTHER_FLAGS}")

case "${CONFIG_NAME}" in
  Debug|Beta|Release) ;;
  *)
    fail "unknown configuration ${CONFIG_NAME}"
    printf '%s\n' "${FAILURES}"
    exit 1
    ;;
esac

if [ -z "${BASE}" ]; then
  fail "PRODUCT_BUNDLE_IDENTIFIER_BASE is empty"
fi

case "${CONFIG_NAME}" in
  Debug)
    EXPECTED_BUNDLE="${BASE}.dev"
    if ! has_token "${FLAGS}" "DEV_LOGIN"; then
      fail "Debug must define DEV_LOGIN"
    fi
    if ! has_token "${FLAGS}" "DEBUG"; then
      fail "Debug must define DEBUG"
    fi
    ;;
  Beta)
    EXPECTED_BUNDLE="${BASE}.beta"
    if ! has_token "${FLAGS}" "DEV_LOGIN"; then
      fail "Beta must define DEV_LOGIN"
    fi
    if has_token "${FLAGS}" "DEBUG"; then
      fail "Beta must not define DEBUG"
    fi
    ;;
  Release)
    EXPECTED_BUNDLE="${BASE}"
    if has_token "${FLAGS}" "DEV_LOGIN"; then
      fail "Release must not define DEV_LOGIN"
    fi
    if has_token "${FLAGS}" "DEBUG"; then
      fail "Release must not define DEBUG"
    fi
    if has_swift_define "${OTHER_FLAGS}" "DEV_LOGIN"; then
      fail "Release OTHER_SWIFT_FLAGS must not pass -DDEV_LOGIN"
    fi
    if has_swift_define "${OTHER_FLAGS}" "DEBUG"; then
      fail "Release OTHER_SWIFT_FLAGS must not pass -DDEBUG"
    fi
    ;;
esac

if [ "${BUNDLE_ID}" != "${EXPECTED_BUNDLE}" ]; then
  fail "bundle id does not match ${CONFIG_NAME} (expected ${EXPECTED_BUNDLE})"
fi

if [ -z "${URL}" ] || [ -z "${KEY}" ] || [ -z "${REF}" ]; then
  if [ "${CONFIG_NAME}" = "Release" ]; then
    fail "Release Production values are empty; refusing to fall back to Development"
  else
    fail "${CONFIG_NAME} is missing SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, or SUPABASE_PROJECT_REF"
  fi
fi

if [ -n "${REF}" ]; then
  REF_LEN=$(printf '%s' "${REF}" | wc -c | tr -d ' ')
  if [ "${REF_LEN}" -ne 20 ]; then
    fail "ref must be 20 characters"
  fi
  if ! printf '%s' "${REF}" | grep -Eq '^[a-z0-9]{20}$'; then
    fail "ref must match [a-z0-9]{20}"
  fi
  if [ "${URL}" != "https://${REF}.supabase.co" ]; then
    fail "SUPABASE_URL must be https://<ref>.supabase.co"
  fi
fi

if [ -n "${KEY}" ]; then
  case "${KEY}" in
    "${KEY_PREFIX}"*) ;;
    *) fail "key must start with ${KEY_PREFIX}" ;;
  esac
  KEY_LOWER=$(printf '%s' "${KEY}" | tr '[:upper:]' '[:lower:]')
  case "${KEY_LOWER}" in
    eyj*) fail "legacy JWT keys are not allowed" ;;
  esac
  case "${KEY_LOWER}" in
    *service_role*) fail "service_role keys are not allowed" ;;
  esac
  case "${KEY_LOWER}" in
    *sb_secret*) fail "secret keys are not allowed" ;;
  esac
fi

case "${CONFIG_NAME}" in
  Debug|Beta)
    if [ -n "${REF}" ] && [ "${REF}" != "${DEV_REF}" ]; then
      fail "Debug/Beta ref must be the Development ref"
    fi
    if [ -n "${REF}" ] && ref_is_blocked "${REF}"; then
      fail "Debug/Beta ref is on the Production blocklist"
    fi
    ;;
  Release)
    if [ -n "${REF}" ] && [ "${REF}" = "${DEV_REF}" ]; then
      fail "Release ref must not be the Development ref"
    fi
    ;;
esac

if [ -n "${FAILURES}" ]; then
  printf '%s\n' "${FAILURES}"
  exit 1
fi

echo "check_env: OK configuration=${CONFIG_NAME} ref=${REF:-<empty>} bundle=${BUNDLE_ID}"
