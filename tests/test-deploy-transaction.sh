#!/bin/bash

set -Eeuo pipefail
umask 077

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  printf 'Deploy transaction test skipped: macOS lockf is required\n'
  exit 0
fi

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly SOURCE_SCRIPT="${ROOT_DIR}/homeserver/scripts/deploy-songyuna-portfolio-ci.sh"
readonly TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/songyuna-deploy-transaction.XXXXXX)"
readonly TEST_APP_DIR="${TEST_ROOT}/app"
readonly TEST_SCRIPT="${TEST_ROOT}/deploy-songyuna-portfolio-ci.sh"
readonly MOCK_DOCKER="${TEST_ROOT}/mock-docker"
readonly DIGEST_ONE=sha256:1111111111111111111111111111111111111111111111111111111111111111
readonly DIGEST_TWO=sha256:2222222222222222222222222222222222222222222222222222222222222222
readonly REVISION_ONE=3333333333333333333333333333333333333333
readonly REVISION_TWO=4444444444444444444444444444444444444444
readonly IMAGE_REPOSITORY=ghcr.io/lalayuna/portfolio

cleanup() {
  if [[ "${TEST_ROOT}" == /private/tmp/songyuna-deploy-transaction.* \
    && -d "${TEST_ROOT}" \
    && ! -L "${TEST_ROOT}" ]]
  then
    /bin/rm -rf -- "${TEST_ROOT}"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  printf 'Deploy transaction test failed: %s\n' "$1" >&2
  exit 1
}

/bin/mkdir -p "${TEST_APP_DIR}"
/bin/cp -p "${SOURCE_SCRIPT}" "${TEST_SCRIPT}"
/usr/bin/sed -i '' \
  -e "s|^readonly APP_DIR=.*$|readonly APP_DIR=${TEST_APP_DIR}|" \
  -e "s|^readonly DOCKER_BIN=.*$|readonly DOCKER_BIN=${MOCK_DOCKER}|" \
  "${TEST_SCRIPT}"
/bin/chmod 700 "${TEST_SCRIPT}"
printf 'services: {}\n' >"${TEST_APP_DIR}/compose.yaml"
/bin/chmod 644 "${TEST_APP_DIR}/compose.yaml"

cat >"${MOCK_DOCKER}" <<'MOCK_DOCKER_EOF'
#!/bin/bash

set -Eeuo pipefail

last_argument=
for argument in "$@"; do
  last_argument="${argument}"
done

case "${1:-}" in
  login)
    registry_token=
    IFS= read -r registry_token || true
    [[ -n "${registry_token}" ]]
    ;;
  pull)
    exit 0
    ;;
  image)
    [[ "${2:-}" == inspect ]] || exit 2
    if [[ "$*" == *org.opencontainers.image.revision* ]]; then
      case "${last_argument}" in
        *"${MOCK_DIGEST_ONE}") printf '%s\n' "${MOCK_REVISION_ONE}" ;;
        *"${MOCK_DIGEST_TWO}") printf '%s\n' "${MOCK_REVISION_TWO}" ;;
        *) exit 2 ;;
      esac
    elif [[ "$*" == *org.opencontainers.image.source* ]]; then
      printf '%s\n' 'https://github.com/LalaYuna/Portfolio'
    fi
    ;;
  compose)
    compose_command=
    for argument in "$@"; do
      case "${argument}" in
        config|up|down)
          compose_command="${argument}"
          break
          ;;
      esac
    done
    case "${compose_command}" in
      config|up)
        exit 0
        ;;
      down)
        printf 'down\n' >"${MOCK_APP_DIR}/down.marker"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  inspect)
    if [[ -n "${MOCK_BAD_DIGEST}" \
      && -f "${MOCK_APP_DIR}/image.env" \
      && "$(/bin/cat "${MOCK_APP_DIR}/image.env")" == *"${MOCK_BAD_DIGEST}"* ]]
    then
      printf 'unhealthy\n'
    else
      printf 'healthy\n'
    fi
    ;;
  exec)
    exit 0
    ;;
  container)
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
MOCK_DOCKER_EOF
/bin/chmod 700 "${MOCK_DOCKER}"

run_deploy() {
  local original_command="$1"
  local bad_digest="${2:-}"

  printf 'test-registry-token\n' \
    | /usr/bin/env \
        SSH_ORIGINAL_COMMAND="${original_command}" \
        MOCK_APP_DIR="${TEST_APP_DIR}" \
        MOCK_BAD_DIGEST="${bad_digest}" \
        MOCK_DIGEST_ONE="${DIGEST_ONE}" \
        MOCK_DIGEST_TWO="${DIGEST_TWO}" \
        MOCK_REVISION_ONE="${REVISION_ONE}" \
        MOCK_REVISION_TWO="${REVISION_TWO}" \
        /bin/bash "${TEST_SCRIPT}"
}

command_one="deploy-songyuna-portfolio ${DIGEST_ONE} ${REVISION_ONE} lalayuna"
command_two="deploy-songyuna-portfolio ${DIGEST_TWO} ${REVISION_TWO} lalayuna"

set +e
run_deploy "${command_two}" "${DIGEST_TWO}" >/dev/null 2>&1
first_failure_status="$?"
set -e
[[ "${first_failure_status}" -eq 1 ]] \
  || fail "first-deploy failure returned ${first_failure_status}, expected 1"
[[ ! -e "${TEST_APP_DIR}/image.env" ]] \
  || fail 'first-deploy failure retained image.env'
[[ ! -e "${TEST_APP_DIR}/deployment.pending" ]] \
  || fail 'first-deploy failure retained pending state after recovery'
[[ ! -e "${TEST_APP_DIR}/deployment.state" ]] \
  || fail 'first-deploy failure created verified state'
[[ -f "${TEST_APP_DIR}/down.marker" ]] \
  || fail 'first-deploy failure did not stop the unverified project'

run_deploy "${command_one}" >/dev/null
/usr/bin/grep -Fxq \
  "CURRENT_IMAGE=${IMAGE_REPOSITORY}@${DIGEST_ONE}" \
  "${TEST_APP_DIR}/deployment.state" \
  || fail 'successful deploy did not record the current image'
/usr/bin/grep -Fxq \
  "CURRENT_REVISION=${REVISION_ONE}" \
  "${TEST_APP_DIR}/deployment.state" \
  || fail 'successful deploy did not record the current revision'
[[ "$(/usr/bin/stat -f '%Lp' "${TEST_APP_DIR}/image.env")" == 600 ]] \
  || fail 'image.env mode is not 0600'
[[ "$(/usr/bin/stat -f '%Lp' "${TEST_APP_DIR}/deployment.state")" == 600 ]] \
  || fail 'deployment.state mode is not 0600'
[[ "$(/usr/bin/stat -f '%Lp' "${TEST_APP_DIR}/deployment.lock")" == 600 ]] \
  || fail 'deployment.lock mode is not 0600'

set +e
run_deploy "${command_two}" "${DIGEST_TWO}" >/dev/null 2>&1
rollback_status="$?"
set -e
[[ "${rollback_status}" -eq 1 ]] \
  || fail "candidate failure returned ${rollback_status}, expected 1"
/usr/bin/grep -Fxq \
  "CURRENT_IMAGE=${IMAGE_REPOSITORY}@${DIGEST_ONE}" \
  "${TEST_APP_DIR}/deployment.state" \
  || fail 'rollback did not preserve the previous verified image'
/usr/bin/grep -Fxq \
  "CURRENT_REVISION=${REVISION_ONE}" \
  "${TEST_APP_DIR}/deployment.state" \
  || fail 'rollback did not preserve the previous verified revision'
/usr/bin/grep -Fxq \
  "SONGYUNA_PORTFOLIO_IMAGE=${IMAGE_REPOSITORY}@${DIGEST_ONE}" \
  "${TEST_APP_DIR}/image.env" \
  || fail 'rollback did not restore image.env'
[[ ! -e "${TEST_APP_DIR}/deployment.pending" ]] \
  || fail 'rollback retained pending state after restoring the verified release'

lock_ready="${TEST_ROOT}/lock.ready"
/usr/bin/lockf -k "${TEST_APP_DIR}/deployment.lock" \
  /bin/sh -c "printf ready >'${lock_ready}'; sleep 2" &
lock_pid="$!"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "${lock_ready}" ]] && break
  /bin/sleep 0.1
done
[[ -f "${lock_ready}" ]] || fail 'lock holder did not start'

set +e
run_deploy "${command_two}" >/dev/null 2>&1
lock_status="$?"
set -e
[[ "${lock_status}" -eq 75 ]] \
  || fail "lock contention returned ${lock_status}, expected 75"
wait "${lock_pid}"

printf 'Deploy transaction tests passed\n'
