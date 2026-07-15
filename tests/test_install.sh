#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="python3"
command -v "${PYTHON_BIN}" >/dev/null 2>&1 || PYTHON_BIN="python"
export CLEAN_MTG_TEST_MODE=1
# shellcheck source=../install.sh
source "${ROOT_DIR}/install.sh"

[[ "${USE_MIDDLE_PROXY}" == "0" ]]
[[ "${ENABLE_BBR}" == "0" ]]

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

CONTROL_SCRIPT="${TEST_DIR}/mtgctl"
bash "${ROOT_DIR}/tests/extract_mtgctl.sh" > "${CONTROL_SCRIPT}"
bash -n "${CONTROL_SCRIPT}"
grep -Fq 'secret=dd%s' "${CONTROL_SCRIPT}"
grep -Fq 'healthcheck ready' "${CONTROL_SCRIPT}"

CONFIG_DIR="${TEST_DIR}/etc"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
STATE_FILE="${CONFIG_DIR}/install.env"
USERS_FILE="${CONFIG_DIR}/users.tsv"
SYSTEMD_FILE="${TEST_DIR}/telemt-proxy.service"
PORT=8443
PUBLIC_HOST="203.0.113.10"
SECRET_LABEL="default"
TELEMT_TAG="3.4.23"
TELEMT_IMAGE="ghcr.io/telemt/telemt:${TELEMT_TAG}"
PREFER_IPV6=0
USE_MIDDLE_PROXY=1
ME2DC_FAST=1

upsert_user default 0123456789abcdef0123456789abcdef
upsert_user family fedcba9876543210fedcba9876543210

[[ "$(user_count)" == "2" ]]
[[ "$(user_secret default)" == "0123456789abcdef0123456789abcdef" ]]
[[ "$(user_secret family)" == "fedcba9876543210fedcba9876543210" ]]

write_config
write_state

docker_bin_path() {
  printf '/usr/bin/docker\n'
}

systemctl() {
  return 0
}

write_systemd_unit

"${PYTHON_BIN}" "${ROOT_DIR}/tests/validate_config.py" "${CONFIG_FILE}"

grep -Fq "PORT='8443'" "${STATE_FILE}"
grep -Fq "PUBLIC_HOST='203.0.113.10'" "${STATE_FILE}"
grep -Fq -- '--publish 8443:3128/tcp' "${SYSTEMD_FILE}"
grep -Fq -- '--user 65532:65532' "${SYSTEMD_FILE}"
grep -Fq -- '--workdir /run/telemt' "${SYSTEMD_FILE}"
grep -Fq -- '--tmpfs /run/telemt:rw' "${SYSTEMD_FILE}"
grep -Fq 'ghcr.io/telemt/telemt:3.4.23 /app/config.toml' "${SYSTEMD_FILE}"
alternate_stop_pattern="docker stop \"\${ALTERNATE_CONTAINER_NAME}\""
alternate_remove_pattern="docker rm -f \"\${ALTERNATE_CONTAINER_NAME}\""
grep -Fq "${alternate_stop_pattern}" "${ROOT_DIR}/install.sh"
if grep -Fq "${alternate_remove_pattern}" "${ROOT_DIR}/install.sh"; then
  echo "alternate proxy must be preserved for rollback" >&2
  exit 1
fi
if grep -Fq 'docker pull' "${SYSTEMD_FILE}"; then
  echo "systemd unit must not pull an image during restart" >&2
  exit 1
fi

remove_user family
[[ "$(user_count)" == "1" ]]
[[ -z "$(user_secret family)" ]]

printf 'install tests passed\n'
