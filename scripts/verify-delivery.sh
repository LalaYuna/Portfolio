#!/bin/bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly WORKFLOW_FILE="${ROOT_DIR}/.github/workflows/delivery.yml"
readonly COMPOSE_FILE="${ROOT_DIR}/homeserver/compose.yaml"
readonly VERIFY_IMAGE="ghcr.io/lalayuna/portfolio@sha256:1111111111111111111111111111111111111111111111111111111111111111"

fail() {
  printf 'Delivery contract verification failed: %s\n' "$1" >&2
  exit 1
}

verify_delivery_git_context() {
  local resolved_workspace

  [[ -e "${ROOT_DIR}/.git" || -L "${ROOT_DIR}/.git" ]] || return 0

  [[ -d "${ROOT_DIR}/.git" && ! -L "${ROOT_DIR}/.git" ]] \
    || fail '.git must be a real directory in a GitHub Actions checkout'
  [[ "${GITHUB_ACTIONS:-}" == true ]] \
    || fail '.git is only allowed in the exact GitHub Actions workspace'
  [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]] \
    || fail 'GITHUB_WORKSPACE must resolve to the delivery root when .git exists'

  resolved_workspace="$(cd "${GITHUB_WORKSPACE}" && pwd -P)" \
    || fail 'GITHUB_WORKSPACE could not be resolved'
  [[ "${resolved_workspace}" == "${ROOT_DIR}" ]] \
    || fail 'GITHUB_WORKSPACE must resolve to the delivery root when .git exists'
}

required_files=(
  .dockerignore
  .github/workflows/delivery.yml
  .gitignore
  Dockerfile
  README.md
  homeserver/README.md
  homeserver/compose.yaml
  homeserver/scripts/deploy-songyuna-portfolio-ci.sh
  nginx.conf
  public/404.html
  public/index.html
  scripts/verify-static-site.py
  scripts/verify-static-site.sh
  tests/test-delivery-git-context.sh
  tests/test-deploy-transaction.sh
  tests/test-deploy-command-guard.sh
)

for relative_path in "${required_files[@]}"; do
  [[ -f "${ROOT_DIR}/${relative_path}" ]] \
    || fail "required file is missing: ${relative_path}"
  [[ ! -L "${ROOT_DIR}/${relative_path}" ]] \
    || fail "symlink is not allowed: ${relative_path}"
done

verify_delivery_git_context

/bin/bash "${ROOT_DIR}/scripts/verify-static-site.sh"

/bin/bash -n "${ROOT_DIR}/scripts/verify-static-site.sh"
/bin/bash -n "${ROOT_DIR}/scripts/verify-delivery.sh"
/bin/bash -n "${ROOT_DIR}/tests/test-delivery-git-context.sh"
/bin/bash -n "${ROOT_DIR}/tests/test-deploy-command-guard.sh"
/bin/bash -n "${ROOT_DIR}/tests/test-deploy-transaction.sh"
/bin/bash -n "${ROOT_DIR}/homeserver/scripts/deploy-songyuna-portfolio-ci.sh"

if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  /bin/bash "${ROOT_DIR}/tests/test-delivery-git-context.sh"
fi

if command -v ruby >/dev/null 2>&1; then
  ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)' \
    "${WORKFLOW_FILE}" \
    >/dev/null
else
  fail 'ruby is required to parse the workflow YAML during focused verification'
fi

action_count=0
while IFS= read -r action_reference; do
  action_count=$((action_count + 1))
  if [[ ! "${action_reference}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ ]]; then
    fail "GitHub Action is not pinned to a full commit SHA: ${action_reference}"
  fi
done < <(
  /usr/bin/awk '/^[[:space:]]*uses:[[:space:]]*/ { print $2 }' "${WORKFLOW_FILE}"
)
[[ "${action_count}" -eq 8 ]] \
  || fail "expected 8 pinned external action uses, found ${action_count}"

gate_count="$(
  /usr/bin/grep -F "vars.MAC_MINI_DEPLOY_ENABLED == 'true'" "${WORKFLOW_FILE}" \
    | /usr/bin/wc -l \
    | /usr/bin/tr -d ' '
)"
[[ "${gate_count}" -eq 2 ]] \
  || fail 'publish and deploy jobs must both use the fail-closed deployment gate'

/usr/bin/grep -Fq 'runs-on: ubuntu-24.04-arm' "${WORKFLOW_FILE}" \
  || fail 'ARM64 validation runner is missing'
/usr/bin/grep -Fq 'IMAGE_NAME: ghcr.io/lalayuna/portfolio' "${WORKFLOW_FILE}" \
  || fail 'approved GHCR image repository is missing'
/usr/bin/grep -Fq 'tags: tag:songyuna-portfolio-ci' "${WORKFLOW_FILE}" \
  || fail 'project-specific Tailscale CI tag is missing'
if /usr/bin/grep -Fq 'tags: tag:ci' "${WORKFLOW_FILE}"; then
  fail 'shared Tailscale CI tag must not be used for this repository'
fi
/usr/bin/grep -Fq 'permissions:' "${WORKFLOW_FILE}" \
  || fail 'workflow permissions are missing'

/usr/bin/grep -Eq '^FROM nginx:[^[:space:]]+@sha256:[0-9a-f]{64}$' "${ROOT_DIR}/Dockerfile" \
  || fail 'Dockerfile base image must use an exact digest'
if /usr/bin/grep -Eq '(^|[^[:alnum:]_-])latest([^[:alnum:]_-]|$)' \
  "${ROOT_DIR}/Dockerfile" "${WORKFLOW_FILE}" "${COMPOSE_FILE}"
then
  fail 'mutable latest reference is not allowed'
fi

/usr/bin/grep -Fq 'USER nginx' "${ROOT_DIR}/Dockerfile" \
  || fail 'Dockerfile must run as nginx user'
/usr/bin/grep -Fq 'listen 8080;' "${ROOT_DIR}/nginx.conf" \
  || fail 'Nginx must listen on 8080'
/usr/bin/grep -Fq 'Content-Security-Policy' "${ROOT_DIR}/nginx.conf" \
  || fail 'Content-Security-Policy header is missing'

if ! command -v docker >/dev/null 2>&1; then
  fail 'docker CLI is required for Compose rendering'
fi

rendered_compose="$(
  SONGYUNA_PORTFOLIO_IMAGE="${VERIFY_IMAGE}" \
    docker compose \
      --project-directory "${ROOT_DIR}/homeserver" \
      --file "${COMPOSE_FILE}" \
      config
)"

/usr/bin/grep -Fq "image: ${VERIFY_IMAGE}" <<<"${rendered_compose}" \
  || fail 'Compose did not preserve the exact digest image'
/usr/bin/grep -Fq 'read_only: true' <<<"${rendered_compose}" \
  || fail 'Compose read_only hardening is missing'
/usr/bin/grep -Fq 'no-new-privileges:true' <<<"${rendered_compose}" \
  || fail 'Compose no-new-privileges hardening is missing'
/usr/bin/grep -Fq 'name: edge' <<<"${rendered_compose}" \
  || fail 'Compose external edge network is missing'

if /usr/bin/grep -Eq '^[[:space:]]+(ports|privileged|devices|volumes):' <<<"${rendered_compose}"; then
  fail 'Compose exposes a forbidden port, privilege, device, or volume'
fi
if /usr/bin/grep -Fq '/var/run/docker.sock' <<<"${rendered_compose}"; then
  fail 'Compose must not mount the Docker socket'
fi

/bin/bash "${ROOT_DIR}/tests/test-deploy-command-guard.sh"

if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
  /bin/bash "${ROOT_DIR}/tests/test-deploy-transaction.sh"
else
  printf 'Deploy transaction test skipped: macOS lockf is required\n'
fi

printf 'Delivery contract verification passed\n'
