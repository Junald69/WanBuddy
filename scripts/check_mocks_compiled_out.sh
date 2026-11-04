#!/usr/bin/env bash
# Confirms mock repositories are present in the debug package build and absent from release.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="${ROOT}/Packages/WanBuddyCore"

build_and_search() {
  config=$1
  swift build --package-path "${PACKAGE}" -c "${config}"
  if grep -R -a -q "MockAuthRepository" "${PACKAGE}/.build/${config}"; then
    return 0
  fi
  return 1
}

echo "Building WanBuddyCore (release) to confirm mocks are compiled out"
if build_and_search release; then
  echo "MockAuthRepository is present in the release build" >&2
  exit 1
fi
echo "release build does not contain MockAuthRepository"

echo "Building WanBuddyCore (debug) to confirm mocks are compiled in"
if ! build_and_search debug; then
  echo "MockAuthRepository is missing from the debug build" >&2
  exit 1
fi
echo "debug build contains MockAuthRepository"
