#!/bin/bash

set -Eeuo pipefail
umask 077

readonly APP_DIR=/Users/homeserver/Server/apps/songyuna-portfolio
readonly COMPOSE_FILE="${APP_DIR}/compose.yaml"
readonly ENV_FILE="${APP_DIR}/image.env"
readonly STATE_FILE="${APP_DIR}/deployment.state"
readonly PENDING_FILE="${APP_DIR}/deployment.pending"
readonly LOCK_FILE="${APP_DIR}/deployment.lock"
readonly CONTAINER_NAME=songyuna-portfolio
readonly IMAGE_REPOSITORY=ghcr.io/lalayuna/portfolio
readonly EXPECTED_SOURCE=https://github.com/LalaYuna/Portfolio
readonly DOCKER_BIN=/usr/local/bin/docker
readonly LOCKF_BIN=/usr/bin/lockf
readonly ZERO_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000

target_digest=
target_revision=
registry_user=
docker_config_dir=
atomic_tmp=
current_image=
current_revision=
previous_image=
previous_revision=

fail() {
  printf 'Song Yuna portfolio deploy failed: %s\n' "$1" >&2
  exit "${2:-1}"
}

cleanup() {
  if [[ -n "${atomic_tmp}" && "${atomic_tmp}" == "${APP_DIR}/"*.tmp.* ]]; then
    /bin/rm -f -- "${atomic_tmp}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${docker_config_dir}" \
    && "${docker_config_dir}" == /private/tmp/songyuna-portfolio-docker.* \
    && -d "${docker_config_dir}" \
    && ! -L "${docker_config_dir}" ]]
  then
    /bin/rm -f -- "${docker_config_dir}/config.json" >/dev/null 2>&1 || true
    /bin/rmdir -- "${docker_config_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

is_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$1" != "${ZERO_DIGEST}" ]]
}

is_revision() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] \
    && [[ "$1" != 0000000000000000000000000000000000000000 ]]
}

is_registry_user() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$ ]]
}

is_approved_image() {
  local image="$1"
  local digest="${image#"${IMAGE_REPOSITORY}@"}"

  [[ "${image}" == "${IMAGE_REPOSITORY}@${digest}" ]] && is_digest "${digest}"
}

parse_forced_command() {
  local original_command="$1"

  if [[ "${original_command}" =~ ^deploy-songyuna-portfolio[[:space:]](sha256:[0-9a-f]{64})[[:space:]]([0-9a-f]{40})[[:space:]]([A-Za-z0-9][A-Za-z0-9_-]{0,38})$ ]]; then
    target_digest="${BASH_REMATCH[1]}"
    target_revision="${BASH_REMATCH[2]}"
    registry_user="${BASH_REMATCH[3]}"
  else
    fail 'forced command is not in the allowlist' 64
  fi

  is_digest "${target_digest}" || fail 'image digest is invalid' 64
  is_revision "${target_revision}" || fail 'commit revision is invalid' 64
  is_registry_user "${registry_user}" || fail 'registry user is invalid' 64
}

assert_regular_file() {
  local description="$1"
  local target="$2"

  if [[ ! -f "${target}" || -L "${target}" ]]; then
    fail "${description} must be a regular non-symlink file: ${target}"
  fi
}

assert_regular_or_missing() {
  local description="$1"
  local target="$2"

  if [[ -L "${target}" ]] \
    || { [[ -e "${target}" ]] && [[ ! -f "${target}" ]]; }
  then
    fail "${description} must be missing or a regular non-symlink file: ${target}"
  fi
}

ensure_runtime() {
  if [[ ! -d "${APP_DIR}" || -L "${APP_DIR}" ]]; then
    fail "application directory is missing or unsafe: ${APP_DIR}"
  fi
  assert_regular_file 'Compose file' "${COMPOSE_FILE}"
  assert_regular_or_missing 'image environment file' "${ENV_FILE}"
  assert_regular_or_missing 'deployment state file' "${STATE_FILE}"
  assert_regular_or_missing 'deployment pending file' "${PENDING_FILE}"
  assert_regular_or_missing 'deployment lock file' "${LOCK_FILE}"

  [[ -x "${DOCKER_BIN}" ]] || fail "Docker is not executable: ${DOCKER_BIN}"
  [[ -x "${LOCKF_BIN}" ]] || fail "lockf is not executable: ${LOCKF_BIN}"
}

acquire_lock() {
  local lock_status

  if ! exec 9>>"${LOCK_FILE}"; then
    fail 'deployment lock file could not be opened'
  fi
  /bin/chmod 600 "${LOCK_FILE}"

  if "${LOCKF_BIN}" -s -t 0 9; then
    return 0
  else
    lock_status="$?"
  fi

  exec 9>&-
  if [[ "${lock_status}" -eq 75 ]]; then
    fail 'another deployment or recovery is already running' 75
  fi
  fail 'deployment lock validation failed'
}

read_value() {
  local key="$1"
  local source_file="$2"

  /usr/bin/sed -n "s/^${key}=//p" "${source_file}"
}

validate_state() {
  local expected_keys
  local keys
  local line_count

  assert_regular_file 'deployment state file' "${STATE_FILE}"
  keys="$(
    /usr/bin/awk -F= 'NF >= 2 { print $1 }' "${STATE_FILE}" \
      | LC_ALL=C /usr/bin/sort
  )"
  expected_keys=$'CURRENT_IMAGE\nCURRENT_REVISION\nPREVIOUS_IMAGE\nPREVIOUS_REVISION'
  [[ "${keys}" == "${expected_keys}" ]] \
    || fail 'deployment state keys are invalid'
  line_count="$(/usr/bin/awk 'END { print NR }' "${STATE_FILE}")"
  [[ "${line_count}" -eq 4 ]] \
    || fail 'deployment state must contain exactly four lines'

  current_image="$(read_value CURRENT_IMAGE "${STATE_FILE}")"
  current_revision="$(read_value CURRENT_REVISION "${STATE_FILE}")"
  previous_image="$(read_value PREVIOUS_IMAGE "${STATE_FILE}")"
  previous_revision="$(read_value PREVIOUS_REVISION "${STATE_FILE}")"

  is_approved_image "${current_image}" \
    || fail 'current image in deployment state is invalid'
  is_revision "${current_revision}" \
    || fail 'current revision in deployment state is invalid'

  if [[ -n "${previous_image}" || -n "${previous_revision}" ]]; then
    is_approved_image "${previous_image}" \
      || fail 'previous image in deployment state is invalid'
    is_revision "${previous_revision}" \
      || fail 'previous revision in deployment state is invalid'
  fi
}

load_state_if_present() {
  current_image=
  current_revision=
  previous_image=
  previous_revision=

  if [[ -f "${STATE_FILE}" ]]; then
    validate_state
  fi
}

write_atomic() {
  local content="$1"
  local mode="$2"
  local target="$3"

  assert_regular_or_missing 'atomic write target' "${target}"
  atomic_tmp="$(/usr/bin/mktemp "${target}.tmp.XXXXXX")"
  [[ "${atomic_tmp}" == "${target}.tmp."* ]] \
    || fail 'temporary file path escaped the approved application directory'

  printf '%s' "${content}" >"${atomic_tmp}"
  /bin/chmod "${mode}" "${atomic_tmp}"
  /bin/mv -f -- "${atomic_tmp}" "${target}"
  atomic_tmp=
}

clear_regular_file() {
  local description="$1"
  local target="$2"

  assert_regular_or_missing "${description}" "${target}"
  /bin/rm -f -- "${target}"
}

write_image_env() {
  local image="$1"

  is_approved_image "${image}" || fail 'refusing to write an unapproved image reference'
  write_atomic "SONGYUNA_PORTFOLIO_IMAGE=${image}"$'\n' 600 "${ENV_FILE}"
}

write_pending() {
  local candidate_image="$1"
  local candidate_revision="$2"
  local rollback_image="$3"
  local rollback_revision="$4"

  write_atomic "$({
    printf 'TARGET_IMAGE=%s\n' "${candidate_image}"
    printf 'TARGET_REVISION=%s\n' "${candidate_revision}"
    printf 'ROLLBACK_IMAGE=%s\n' "${rollback_image}"
    printf 'ROLLBACK_REVISION=%s\n' "${rollback_revision}"
  })"$'\n' 600 "${PENDING_FILE}"
}

write_state() {
  local new_current_image="$1"
  local new_current_revision="$2"
  local new_previous_image="$3"
  local new_previous_revision="$4"

  write_atomic "$({
    printf 'CURRENT_IMAGE=%s\n' "${new_current_image}"
    printf 'CURRENT_REVISION=%s\n' "${new_current_revision}"
    printf 'PREVIOUS_IMAGE=%s\n' "${new_previous_image}"
    printf 'PREVIOUS_REVISION=%s\n' "${new_previous_revision}"
  })"$'\n' 600 "${STATE_FILE}"
}

validate_current_env() {
  local expected_content
  local env_image

  if [[ -n "${current_image}" ]]; then
    assert_regular_file 'image environment file' "${ENV_FILE}"
    expected_content="SONGYUNA_PORTFOLIO_IMAGE=${current_image}"
    [[ "$(/bin/cat "${ENV_FILE}")" == "${expected_content}" ]] \
      || fail 'image environment file has unexpected content'
    env_image="$(read_value SONGYUNA_PORTFOLIO_IMAGE "${ENV_FILE}")"
    [[ "${env_image}" == "${current_image}" ]] \
      || fail 'image environment file does not match verified deployment state'
    return 0
  fi

  if [[ -e "${ENV_FILE}" || -L "${ENV_FILE}" ]]; then
    fail 'unverified image environment file exists without deployment state; recover first'
  fi
}

compose() {
  "${DOCKER_BIN}" compose \
    --project-name songyuna-portfolio \
    --project-directory "${APP_DIR}" \
    --file "${COMPOSE_FILE}" \
    --env-file "${ENV_FILE}" \
    "$@"
}

compose_up() {
  compose config --quiet \
    && compose up \
      --detach \
      --pull never \
      --no-build \
      --remove-orphans
}

wait_for_healthy_site() {
  local health_status
  local iteration

  iteration=0
  while [[ "${iteration}" -lt 30 ]]; do
    health_status="$(
      "${DOCKER_BIN}" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
        "${CONTAINER_NAME}" \
        2>/dev/null \
        || true
    )"

    if [[ "${health_status}" == healthy ]]; then
      "${DOCKER_BIN}" exec "${CONTAINER_NAME}" \
        wget -q -O /dev/null http://127.0.0.1:8080/health \
        || return 1
      "${DOCKER_BIN}" exec "${CONTAINER_NAME}" \
        wget -q -O /dev/null http://127.0.0.1:8080/ \
        || return 1
      return 0
    fi
    if [[ "${health_status}" == unhealthy ]]; then
      return 1
    fi

    /bin/sleep 2
    iteration=$((iteration + 1))
  done

  return 1
}

verify_image_labels() {
  local actual_revision
  local actual_source
  local image_ref="$1"
  local expected_revision="$2"

  actual_revision="$(
    "${DOCKER_BIN}" image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
      "${image_ref}"
  )"
  actual_source="$(
    "${DOCKER_BIN}" image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' \
      "${image_ref}"
  )"

  [[ "${actual_revision}" == "${expected_revision}" ]] \
    || fail 'pulled image revision label does not match the requested commit'
  [[ "${actual_source}" == "${EXPECTED_SOURCE}" ]] \
    || fail 'pulled image source label is not the approved repository'
}

registry_login_and_pull() {
  local extra_input
  local image_ref="$1"
  local registry_token

  docker_config_dir="$(
    /usr/bin/mktemp -d /private/tmp/songyuna-portfolio-docker.XXXXXX
  )"
  [[ "${docker_config_dir}" == /private/tmp/songyuna-portfolio-docker.* ]] \
    || fail 'Docker authentication directory escaped the approved prefix'

  registry_token=
  if ! IFS= read -r registry_token; then
    [[ -n "${registry_token}" ]] || fail 'registry token was not provided on stdin' 64
  fi
  [[ -n "${registry_token}" ]] || fail 'registry token was not provided on stdin' 64
  extra_input=
  if IFS= read -r extra_input || [[ -n "${extra_input}" ]]; then
    fail 'registry token input must contain exactly one line' 64
  fi
  [[ "${#registry_token}" -le 4096 ]] \
    || fail 'registry token input is unexpectedly long' 64

  if ! printf '%s' "${registry_token}" \
    | DOCKER_CONFIG="${docker_config_dir}" "${DOCKER_BIN}" login \
      ghcr.io \
      --username "${registry_user}" \
      --password-stdin \
      >/dev/null
  then
    registry_token=
    fail 'GHCR authentication failed'
  fi
  registry_token=

  DOCKER_CONFIG="${docker_config_dir}" "${DOCKER_BIN}" pull "${image_ref}"
}

rollback_candidate() {
  local rollback_image="$1"

  if [[ -n "${rollback_image}" ]]; then
    is_approved_image "${rollback_image}" || return 1
    "${DOCKER_BIN}" image inspect "${rollback_image}" >/dev/null 2>&1 || return 1
    write_image_env "${rollback_image}"
    compose_up || return 1
    wait_for_healthy_site || return 1
    return 0
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    compose down --remove-orphans || return 1
    clear_regular_file 'image environment file' "${ENV_FILE}"
  fi
  return 0
}

perform_deploy() {
  local candidate_image
  local rollback_image
  local rollback_revision

  ensure_runtime
  acquire_lock
  if [[ -e "${PENDING_FILE}" || -L "${PENDING_FILE}" ]]; then
    fail 'an unfinished deployment exists; run the local recover command first'
  fi

  load_state_if_present
  validate_current_env
  rollback_image="${current_image}"
  rollback_revision="${current_revision}"
  candidate_image="${IMAGE_REPOSITORY}@${target_digest}"

  registry_login_and_pull "${candidate_image}"
  verify_image_labels "${candidate_image}" "${target_revision}"

  write_pending \
    "${candidate_image}" \
    "${target_revision}" \
    "${rollback_image}" \
    "${rollback_revision}"
  write_image_env "${candidate_image}"

  if compose_up && wait_for_healthy_site; then
    write_state \
      "${candidate_image}" \
      "${target_revision}" \
      "${rollback_image}" \
      "${rollback_revision}"
    clear_regular_file 'deployment pending file' "${PENDING_FILE}"
    printf 'Song Yuna portfolio deployment succeeded: revision=%s digest=%s\n' \
      "${target_revision}" \
      "${target_digest}"
    return 0
  fi

  printf 'Candidate failed health verification; attempting exact rollback\n' >&2
  if rollback_candidate "${rollback_image}"; then
    clear_regular_file 'deployment pending file' "${PENDING_FILE}"
    fail 'candidate failed; previous verified state was restored'
  fi

  fail 'candidate and rollback both failed; pending state was retained for recovery'
}

perform_recovery() {
  local unverified_env_image

  ensure_runtime
  acquire_lock
  load_state_if_present

  if [[ -n "${current_image}" ]]; then
    "${DOCKER_BIN}" image inspect "${current_image}" >/dev/null 2>&1 \
      || fail 'verified current image is not available locally for recovery'
    write_image_env "${current_image}"
    compose_up || fail 'Compose recovery failed'
    wait_for_healthy_site || fail 'recovered container did not become healthy'
    clear_regular_file 'deployment pending file' "${PENDING_FILE}"
    printf 'Song Yuna portfolio recovery succeeded: revision=%s\n' \
      "${current_revision}"
    return 0
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    unverified_env_image="$(read_value SONGYUNA_PORTFOLIO_IMAGE "${ENV_FILE}")"
    is_approved_image "${unverified_env_image}" \
      || fail 'first-deploy recovery found an invalid image environment file'
    [[ "$(/bin/cat "${ENV_FILE}")" == "SONGYUNA_PORTFOLIO_IMAGE=${unverified_env_image}" ]] \
      || fail 'first-deploy recovery found unexpected environment content'
    compose down --remove-orphans \
      || fail 'first-deploy recovery could not stop the unverified project'
    clear_regular_file 'image environment file' "${ENV_FILE}"
  elif "${DOCKER_BIN}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    fail 'container exists without verified state or image environment file'
  fi

  clear_regular_file 'deployment pending file' "${PENDING_FILE}"
  printf 'First-deploy recovery completed; no verified release was available\n'
}

if [[ "${1:-}" == --validate-forced-command ]]; then
  [[ "$#" -eq 2 ]] || fail 'validate mode requires exactly one command string' 64
  [[ -z "${SSH_ORIGINAL_COMMAND:-}" ]] \
    || fail 'validate mode is available only as a direct local check' 64
  parse_forced_command "$2"
  printf 'Forced command is valid\n'
  exit 0
fi

if [[ "${1:-}" == recover ]]; then
  [[ "$#" -eq 1 ]] || fail 'recover accepts no additional arguments' 64
  [[ -z "${SSH_ORIGINAL_COMMAND:-}" ]] \
    || fail 'recover is available only as a direct local command' 64
  perform_recovery
  exit 0
fi

[[ "$#" -eq 0 ]] || fail 'direct arguments are not allowed over the CI entrypoint' 64
parse_forced_command "${SSH_ORIGINAL_COMMAND:-}"
perform_deploy
