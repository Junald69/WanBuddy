#!/usr/bin/env bash
# A fail-closed run check, not an authorization boundary for Repository Secrets.
set -euo pipefail
[[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]
[[ "${GITHUB_REPOSITORY:-}" == Junald69/WanBuddy ]]
[[ "${GITHUB_REF:-}" == refs/heads/main ]]
[[ "${GITHUB_REPOSITORY_OWNER:-}" == Junald69 ]]
[[ "${GITHUB_ACTOR:-}" == Junald69 ]]
[[ "${GITHUB_TRIGGERING_ACTOR:-}" == Junald69 ]]
[[ "${APPROVED_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]
[[ "${APPROVED_COMMIT}" == "${GITHUB_SHA:-}" ]]
case "${OPERATION:-}" in validate|upload) ;; *) exit 1 ;; esac
echo 'Owner/main/manual run and approved commit verified'
