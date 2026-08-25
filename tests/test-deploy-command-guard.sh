#!/bin/bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly DEPLOY_SCRIPT="${ROOT_DIR}/homeserver/scripts/deploy-songyuna-portfolio-ci.sh"
readonly VALID_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
readonly VALID_REVISION=2222222222222222222222222222222222222222
readonly VALID_COMMAND="deploy-songyuna-portfolio ${VALID_DIGEST} ${VALID_REVISION} lalayuna"

expect_status() {
  local expected_status="$1"
  local description="$2"
  local actual_status

  shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual_status="$?"
  set -e

  if [[ "${actual_status}" -ne "${expected_status}" ]]; then
    printf 'Unexpected status for %s: expected=%s actual=%s\n' \
      "${description}" \
      "${expected_status}" \
      "${actual_status}" \
      >&2
    exit 1
  fi
}

expect_status 0 \
  'valid forced command parser check' \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command "${VALID_COMMAND}"

expect_status 64 \
  'arbitrary SSH command' \
  /usr/bin/env SSH_ORIGINAL_COMMAND='uname -a' /bin/bash "${DEPLOY_SCRIPT}"

expect_status 64 \
  'remote recovery attempt' \
  /usr/bin/env SSH_ORIGINAL_COMMAND='recover' /bin/bash "${DEPLOY_SCRIPT}"

expect_status 64 \
  'digest with non-hex character' \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command \
  "deploy-songyuna-portfolio sha256:zz11111111111111111111111111111111111111111111111111111111111111 ${VALID_REVISION} lalayuna"

expect_status 64 \
  'uppercase revision' \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command \
  "deploy-songyuna-portfolio ${VALID_DIGEST} A222222222222222222222222222222222222222 lalayuna"

expect_status 64 \
  'shell metacharacter injection' \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command \
  "${VALID_COMMAND}; touch /private/tmp/not-allowed"

expect_status 64 \
  'extra argument' \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command \
  "${VALID_COMMAND} extra"

expect_status 64 \
  'validate mode through SSH' \
  /usr/bin/env SSH_ORIGINAL_COMMAND="${VALID_COMMAND}" \
  /bin/bash "${DEPLOY_SCRIPT}" --validate-forced-command "${VALID_COMMAND}"

printf 'Deploy forced-command guard tests passed\n'
