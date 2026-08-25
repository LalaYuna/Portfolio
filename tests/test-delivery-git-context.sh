#!/bin/bash

set -Eeuo pipefail
umask 077

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_PARENT="${TMPDIR:-/tmp}"
readonly TEST_ROOT="$(
  /usr/bin/mktemp -d \
    "${TEST_PARENT%/}/songyuna-delivery-git-context.XXXXXX"
)"
readonly FIXTURE_ROOT="${TEST_ROOT}/repository"
readonly OUTSIDE_ROOT="${TEST_ROOT}/outside"

cleanup() {
  if [[ "${TEST_ROOT}" == "${TEST_PARENT%/}"/songyuna-delivery-git-context.* \
    && -d "${TEST_ROOT}" \
    && ! -L "${TEST_ROOT}" ]]
  then
    /bin/rm -rf -- "${TEST_ROOT}"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  printf 'Delivery Git context test failed: %s\n' "$1" >&2
  exit 1
}

run_expected_failure() {
  local label="$1"
  local expected_message="$2"
  local output_file="${TEST_ROOT}/${label}.log"
  local actual_rc
  shift 2

  set +e
  "$@" >"${output_file}" 2>&1
  actual_rc="$?"
  set -e

  [[ "${actual_rc}" -eq 1 ]] \
    || fail "${label} returned ${actual_rc}, expected 1"
  /usr/bin/grep -Fq "${expected_message}" "${output_file}" \
    || fail "${label} did not report the expected boundary failure"
}

/bin/mkdir -p "${FIXTURE_ROOT}" "${OUTSIDE_ROOT}"
/bin/cp -R "${ROOT_DIR}/." "${FIXTURE_ROOT}"
/bin/mkdir "${FIXTURE_ROOT}/.git"

run_expected_failure \
  local-git-root \
  '.git is only allowed in the exact GitHub Actions workspace' \
  /usr/bin/env \
    -u GITHUB_ACTIONS \
    -u GITHUB_WORKSPACE \
    /bin/bash "${FIXTURE_ROOT}/scripts/verify-delivery.sh"

run_expected_failure \
  wrong-github-workspace \
  'GITHUB_WORKSPACE must resolve to the delivery root when .git exists' \
  /usr/bin/env \
    GITHUB_ACTIONS=true \
    GITHUB_WORKSPACE="${OUTSIDE_ROOT}" \
    /bin/bash "${FIXTURE_ROOT}/scripts/verify-delivery.sh"

/bin/rmdir "${FIXTURE_ROOT}/.git"
/bin/ln -s "${TEST_ROOT}/missing-git-target" "${FIXTURE_ROOT}/.git"
run_expected_failure \
  symlink-git-root \
  '.git must be a real directory in a GitHub Actions checkout' \
  /usr/bin/env \
    GITHUB_ACTIONS=true \
    GITHUB_WORKSPACE="${FIXTURE_ROOT}" \
    /bin/bash "${FIXTURE_ROOT}/scripts/verify-delivery.sh"
/bin/unlink "${FIXTURE_ROOT}/.git"
/bin/mkdir "${FIXTURE_ROOT}/.git"

if ! /usr/bin/env \
  GITHUB_ACTIONS=true \
  GITHUB_WORKSPACE="${FIXTURE_ROOT}" \
  /bin/bash "${FIXTURE_ROOT}/scripts/verify-delivery.sh" \
  >"${TEST_ROOT}/exact-github-workspace.log" 2>&1
then
  /bin/cat "${TEST_ROOT}/exact-github-workspace.log" >&2
  fail 'exact GitHub Actions workspace was rejected'
fi
/usr/bin/grep -Fq \
  'Delivery contract verification passed' \
  "${TEST_ROOT}/exact-github-workspace.log" \
  || fail 'exact GitHub Actions workspace did not complete delivery verification'

printf 'Delivery Git context tests passed\n'
