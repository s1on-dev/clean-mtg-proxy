#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="telemt-proxy.service"
LEGACY_SERVICE_NAME="mtg.service"
CONTAINER_NAME="telemt-proxy"
LEGACY_CONTAINER_NAME="mtg-proxy"
ALTERNATE_CONTAINER_NAME="mtprotoproxy"
CONFIG_DIR="/etc/clean-mtg-proxy"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
STATE_FILE="${CONFIG_DIR}/install.env"
USERS_FILE="${CONFIG_DIR}/users.tsv"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONTROL_BIN="/usr/local/bin/mtgctl"

PORT="${PORT:-443}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
SECRET="${SECRET:-}"
SECRET_LABEL="${SECRET_LABEL:-default}"
TELEMT_TAG="${TELEMT_TAG:-3.4.23}"
TELEMT_IMAGE="${TELEMT_IMAGE:-ghcr.io/telemt/telemt:${TELEMT_TAG}}"
PREFER_IPV6="${PREFER_IPV6:-0}"
USE_MIDDLE_PROXY="${USE_MIDDLE_PROXY:-1}"
ME2DC_FAST="${ME2DC_FAST:-1}"

INSTALL_DOCKER=1
ALLOW_DOCKER_SCRIPT=1
CONFIGURE_FIREWALL=1
IPTABLES_FALLBACK=0
RUN_DOCTOR=1
STRICT_DOCTOR=1
RUN_SPEEDTEST=0
RUN_BBR_NAT_CHECK=0
START_SERVICE=1
BASE_PACKAGES_READY=0
LEGACY_OPTIONS_USED=0

usage() {
  cat <<'EOF'
Clean MTProto proxy installer (Telemt secure mode).

Usage:
  sudo bash install.sh
  sudo bash install.sh --port 443 [options]

Options:
  --port PORT              Public TCP port, default: 443
  --server HOST            Public IPv4 or DNS name used in Telegram links
  --secret SECRET          32 hexadecimal characters
  --secret-label LABEL     Secret label, default: default
  --tag TAG                Telemt container tag, default: 3.4.23
  --image IMAGE            Full container image override
  --prefer-ipv6            Prefer IPv6 for Telegram upstream connections
  --direct                 Disable Telegram Middle-End and use Direct-DC
  --middle-proxy           Use Telegram Middle-End with Direct-DC fallback, default
  --bbr-nat-check          Run optional BBR/NAT diagnostics
  --skip-docker-install    Require Docker to be installed already
  --no-docker-script       Do not fall back to https://get.docker.com
  --skip-firewall          Do not change the local firewall
  --iptables-fallback      Add a non-persistent INPUT accept rule if needed
  --skip-doctor            Skip readiness diagnostics
  --no-strict-doctor       Do not fail installation when readiness is not reached
  --speedtest              Run download and Telegram TCP checks after install
  --no-start               Write configuration without starting the service
  -h, --help               Show this help

Compatibility:
  Old FakeTLS options such as --domain and --disable-nginx-disguise are
  accepted and ignored. Telemt secure mode does not use a domain or Nginx.

Non-interactive example:
  sudo bash install.sh --port 443 --server 203.0.113.10
EOF
}

log() {
  printf '\033[1;32m[+] %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31m[-] %s\033[0m\n' "$*" >&2
  exit 1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

pause() {
  read -r -p "Press Enter to continue..." _
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
  cmd_exists systemctl || die "systemd is required"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
  TELEMT_IMAGE="${TELEMT_IMAGE:-ghcr.io/telemt/telemt:${TELEMT_TAG}}"
}

validate_label() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "Secret label may contain only letters, numbers, underscore and dash"
}

validate_secret() {
  [[ "$1" =~ ^[0-9A-Fa-f]{32}$ ]] || die "Secret must contain exactly 32 hexadecimal characters"
}

validate_host() {
  [[ -n "$1" ]] || die "Public host is empty"
  [[ "$1" =~ ^[A-Za-z0-9:.-]+$ ]] || die "Public host contains unsupported characters: $1"
}

validate_input() {
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535"
  validate_label "${SECRET_LABEL}"
  [[ -z "${SECRET}" ]] || validate_secret "${SECRET}"
  [[ -z "${PUBLIC_HOST}" ]] || validate_host "${PUBLIC_HOST}"
  [[ "${TELEMT_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Container tag contains unsupported characters"
  [[ "${TELEMT_IMAGE}" =~ ^[A-Za-z0-9./:_@-]+$ ]] || die "Container image contains unsupported characters"
  case "${PREFER_IPV6}" in 0|1) ;; *) die "PREFER_IPV6 must be 0 or 1" ;; esac
  case "${USE_MIDDLE_PROXY}" in 0|1) ;; *) die "USE_MIDDLE_PROXY must be 0 or 1" ;; esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [[ $# -ge 2 ]] || die "Missing value for --port"
        PORT="$2"; shift 2 ;;
      --server|--public-host)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        PUBLIC_HOST="$2"; shift 2 ;;
      --secret)
        [[ $# -ge 2 ]] || die "Missing value for --secret"
        SECRET="$2"; shift 2 ;;
      --secret-label)
        [[ $# -ge 2 ]] || die "Missing value for --secret-label"
        SECRET_LABEL="$2"; shift 2 ;;
      --tag)
        [[ $# -ge 2 ]] || die "Missing value for --tag"
        TELEMT_TAG="$2"
        TELEMT_IMAGE="ghcr.io/telemt/telemt:${TELEMT_TAG}"
        shift 2 ;;
      --image)
        [[ $# -ge 2 ]] || die "Missing value for --image"
        TELEMT_IMAGE="$2"; shift 2 ;;
      --prefer-ipv6)
        PREFER_IPV6=1; shift ;;
      --direct)
        USE_MIDDLE_PROXY=0; shift ;;
      --middle-proxy)
        USE_MIDDLE_PROXY=1; shift ;;
      --bbr-nat-check)
        RUN_BBR_NAT_CHECK=1; shift ;;
      --skip-docker-install)
        INSTALL_DOCKER=0; shift ;;
      --no-docker-script)
        ALLOW_DOCKER_SCRIPT=0; shift ;;
      --skip-firewall)
        CONFIGURE_FIREWALL=0; shift ;;
      --iptables-fallback)
        IPTABLES_FALLBACK=1; shift ;;
      --skip-doctor)
        RUN_DOCTOR=0; shift ;;
      --strict-doctor)
        STRICT_DOCTOR=1; shift ;;
      --no-strict-doctor)
        STRICT_DOCTOR=0; shift ;;
      --speedtest)
        RUN_SPEEDTEST=1; shift ;;
      --skip-speedtest)
        RUN_SPEEDTEST=0; shift ;;
      --no-start)
        START_SERVICE=0; shift ;;
      --domain|--fronting-host|--prefer-ip|--concurrency|--dns|--blocklist|--allowlist|--disguise-server-name|--disguise-port)
        [[ $# -ge 2 ]] || die "Missing value for legacy option $1"
        LEGACY_OPTIONS_USED=1; shift 2 ;;
      --enable-blocklist|--disable-blocklist|--nginx-disguise|--disable-nginx-disguise)
        LEGACY_OPTIONS_USED=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

detect_pkg_manager() {
  if cmd_exists apt-get; then
    printf 'apt\n'
  elif cmd_exists dnf; then
    printf 'dnf\n'
  elif cmd_exists yum; then
    printf 'yum\n'
  else
    printf 'unknown\n'
  fi
}

install_packages() {
  local pm
  [[ "${BASE_PACKAGES_READY}" -eq 0 ]] || return
  pm="$(detect_pkg_manager)"
  log "Installing base packages (${pm})"

  case "${pm}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl iproute2 iptables openssl coreutils
      apt-get install -y qrencode || warn "qrencode is unavailable; QR output will be skipped"
      ;;
    dnf)
      dnf install -y ca-certificates curl iproute iptables openssl coreutils
      dnf install -y qrencode || warn "qrencode is unavailable; QR output will be skipped"
      ;;
    yum)
      yum install -y ca-certificates curl iproute iptables openssl coreutils
      yum install -y qrencode || warn "qrencode is unavailable; QR output will be skipped"
      ;;
    *)
      warn "Unknown package manager; using existing tools"
      ;;
  esac
  BASE_PACKAGES_READY=1
}

install_docker_from_packages() {
  case "$(detect_pkg_manager)" in
    apt) apt-get install -y docker.io ;;
    dnf) dnf install -y moby-engine || dnf install -y docker ;;
    yum) yum install -y moby-engine || yum install -y docker ;;
    *) return 1 ;;
  esac
}

install_docker_official_script() {
  [[ "${ALLOW_DOCKER_SCRIPT}" -eq 1 ]] || return 1
  cmd_exists curl || return 1
  warn "Using Docker's official convenience script"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
}

ensure_docker() {
  if ! cmd_exists docker; then
    [[ "${INSTALL_DOCKER}" -eq 1 ]] || die "Docker is not installed"
    install_packages
    log "Installing Docker"
    install_docker_from_packages || install_docker_official_script || die "Docker installation failed"
  fi
  systemctl enable --now docker
  docker info >/dev/null || die "Docker daemon is not responding"
}

detect_public_ipv4() {
  local ip
  if cmd_exists curl; then
    ip="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '\r\n ' || true)"
    [[ -n "${ip}" ]] || ip="$(curl -4 -fsS --max-time 6 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}"
}

ensure_public_host() {
  if [[ -z "${PUBLIC_HOST}" ]]; then
    PUBLIC_HOST="$(detect_public_ipv4 || true)"
  fi
  [[ -n "${PUBLIC_HOST}" ]] || die "Could not detect public IPv4; pass --server HOST"
  validate_host "${PUBLIC_HOST}"
}

generate_secret() {
  openssl rand -hex 16
}

users_init() {
  mkdir -p "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"
  [[ -f "${USERS_FILE}" ]] || : > "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}"
}

user_count() {
  users_init
  awk -F'\t' 'NF >= 2 {n++} END {print n + 0}' "${USERS_FILE}"
}

user_exists() {
  local label="$1"
  users_init
  awk -F'\t' -v label="${label}" 'NF >= 2 && $1 == label {found=1} END {exit !found}' "${USERS_FILE}"
}

user_secret() {
  local label="$1"
  users_init
  awk -F'\t' -v label="${label}" 'NF >= 2 && $1 == label {print $2; exit}' "${USERS_FILE}"
}

upsert_user() {
  local label="$1" secret="$2" now tmp
  validate_label "${label}"
  validate_secret "${secret}"
  users_init
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  awk -F'\t' -v label="${label}" 'BEGIN{OFS=FS} NF >= 2 && $1 != label {print}' "${USERS_FILE}" > "${tmp}"
  printf '%s\t%s\t%s\n' "${label}" "${secret,,}" "${now}" >> "${tmp}"
  mv "${tmp}" "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}"
}

remove_user() {
  local label="$1" tmp
  users_init
  tmp="$(mktemp)"
  awk -F'\t' -v label="${label}" 'BEGIN{OFS=FS} NF >= 2 && $1 != label {print}' "${USERS_FILE}" > "${tmp}"
  mv "${tmp}" "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}"
}

list_users() {
  users_init
  awk -F'\t' 'NF >= 2 {printf "%d) %s  created=%s\n", ++n, $1, $3} END {if (!n) print "No users"}' "${USERS_FILE}"
}

select_user_label() {
  local choice count label
  count="$(user_count)"
  (( count > 0 )) || die "No proxy users"
  list_users >&2
  read -r -p "Choose user number: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid user number"
  (( choice >= 1 && choice <= count )) || die "User number is out of range"
  label="$(awk -F'\t' -v n="${choice}" 'NF >= 2 {i++; if (i==n) {print $1; exit}}' "${USERS_FILE}")"
  [[ -n "${label}" ]] || die "Could not select user"
  printf '%s\n' "${label}"
}

ensure_initial_user() {
  users_init
  if [[ -n "${SECRET}" ]]; then
    upsert_user "${SECRET_LABEL}" "${SECRET}"
  elif [[ "$(user_count)" -eq 0 ]]; then
    SECRET="$(generate_secret)"
    upsert_user "${SECRET_LABEL}" "${SECRET}"
  fi
}

backup_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    cp -a "${path}" "${path}.$(date +%Y%m%d-%H%M%S).bak"
  fi
}

write_config() {
  local prefer_ipv6 middle_proxy me2dc_fast label secret
  prefer_ipv6=false
  middle_proxy=false
  me2dc_fast=false
  [[ "${PREFER_IPV6}" -eq 1 ]] && prefer_ipv6=true
  [[ "${USE_MIDDLE_PROXY}" -eq 1 ]] && middle_proxy=true
  [[ "${ME2DC_FAST}" -eq 1 ]] && me2dc_fast=true

  log "Writing ${CONFIG_FILE}"
  mkdir -p "${CONFIG_DIR}"
  backup_file "${CONFIG_FILE}"
  {
    cat <<EOF
[general]
use_middle_proxy = ${middle_proxy}
prefer_ipv6 = ${prefer_ipv6}
me2dc_fallback = true
me2dc_fast = ${me2dc_fast}
log_level = "normal"

[general.modes]
classic = false
secure = true
tls = false

[general.links]
show = []
public_host = "${PUBLIC_HOST}"
public_port = ${PORT}

[server]
port = 3128

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
read_only = true
minimal_runtime_enabled = false

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
mask = false
tls_emulation = false

[access.users]
EOF
    while IFS=$'\t' read -r label secret _; do
      [[ -n "${label}" && -n "${secret}" ]] || continue
      printf '"%s" = "%s"\n' "${label}" "${secret}"
    done < "${USERS_FILE}"
  } > "${CONFIG_FILE}"
  chmod 0640 "${CONFIG_FILE}"
  if [[ "${CLEAN_MTG_TEST_MODE:-0}" != "1" ]]; then
    chown 0:65532 "${CONFIG_FILE}"
  fi
}

write_state() {
  {
    printf 'PORT=%s\n' "$(shell_quote "${PORT}")"
    printf 'PUBLIC_HOST=%s\n' "$(shell_quote "${PUBLIC_HOST}")"
    printf 'SECRET_LABEL=%s\n' "$(shell_quote "${SECRET_LABEL}")"
    printf 'TELEMT_TAG=%s\n' "$(shell_quote "${TELEMT_TAG}")"
    printf 'TELEMT_IMAGE=%s\n' "$(shell_quote "${TELEMT_IMAGE}")"
    printf 'PREFER_IPV6=%s\n' "$(shell_quote "${PREFER_IPV6}")"
    printf 'USE_MIDDLE_PROXY=%s\n' "$(shell_quote "${USE_MIDDLE_PROXY}")"
    printf 'ME2DC_FAST=%s\n' "$(shell_quote "${ME2DC_FAST}")"
  } > "${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
}

docker_bin_path() {
  command -v docker
}

write_systemd_unit() {
  local docker_bin
  docker_bin="$(docker_bin_path)"
  log "Writing ${SYSTEMD_FILE}"
  cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=Clean MTProto proxy (Telemt secure mode)
Documentation=https://github.com/telemt/telemt
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=20
LimitNOFILE=262144
ExecStartPre=/bin/sh -c '${docker_bin} rm -f ${CONTAINER_NAME} >/dev/null 2>&1 || true'
ExecStart=${docker_bin} run --rm --name ${CONTAINER_NAME} \\
  --publish ${PORT}:3128/tcp \\
  --volume ${CONFIG_FILE}:/app/config.toml:ro \\
  --user 65532:65532 \\
  --workdir /run/telemt \\
  --read-only \\
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \\
  --tmpfs /run/telemt:rw,nosuid,nodev,noexec,mode=1777,size=16m \\
  --cap-drop ALL \\
  --security-opt no-new-privileges:true \\
  --ulimit nofile=65536:262144 \\
  --log-driver json-file \\
  --log-opt max-size=10m \\
  --log-opt max-file=5 \\
  ${TELEMT_IMAGE} /app/config.toml
ExecStop=-${docker_bin} stop -t 10 ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SYSTEMD_FILE}"
  systemctl daemon-reload
}

write_control_script() {
  log "Writing ${CONTROL_BIN}"
  cat > "${CONTROL_BIN}" <<'CONTROL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="telemt-proxy.service"
CONTAINER_NAME="telemt-proxy"
CONFIG_DIR="/etc/clean-mtg-proxy"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
STATE_FILE="${CONFIG_DIR}/install.env"
USERS_FILE="${CONFIG_DIR}/users.tsv"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONTROL_BIN="/usr/local/bin/mtgctl"
PORT="443"
PUBLIC_HOST=""
TELEMT_IMAGE="ghcr.io/telemt/telemt:3.4.23"

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

usage() {
  cat <<'EOF'
mtgctl commands:
  status                 Service, container and listener status
  logs [LINES]           Recent logs
  follow                 Follow logs
  doctor                 Liveness, readiness, port and Telegram checks
  access [LABEL]         Show secure proxy links
  qr [LABEL]             Show links and local QR codes
  users                  List proxy users
  add LABEL [SECRET]     Add an active secret
  revoke LABEL           Revoke a secret (last secret is protected)
  regenerate LABEL       Replace a secret
  speedtest              Telegram TCP and HTTPS speed checks
  bbr-nat                Show BBR, NAT and listener information
  update                 Pull the configured image and restart
  restart|start|stop     Control the service
  uninstall [--purge]    Remove service; optionally remove configuration
EOF
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
}

validate_label() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid label" >&2; exit 1; }
}

validate_secret() {
  [[ "$1" =~ ^[0-9A-Fa-f]{32}$ ]] || { echo "Secret must be 32 hex characters" >&2; exit 1; }
}

generate_secret() {
  openssl rand -hex 16
}

user_secret() {
  local label="$1"
  awk -F'\t' -v label="${label}" 'NF >= 2 && $1 == label {print $2; exit}' "${USERS_FILE}" 2>/dev/null || true
}

user_count() {
  awk -F'\t' 'NF >= 2 {n++} END {print n + 0}' "${USERS_FILE}" 2>/dev/null || printf '0\n'
}

upsert_user() {
  local label="$1" secret="$2" now tmp
  validate_label "${label}"
  validate_secret "${secret}"
  mkdir -p "${CONFIG_DIR}"
  touch "${USERS_FILE}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  awk -F'\t' -v label="${label}" 'BEGIN{OFS=FS} NF >= 2 && $1 != label {print}' "${USERS_FILE}" > "${tmp}"
  printf '%s\t%s\t%s\n' "${label}" "${secret,,}" "${now}" >> "${tmp}"
  mv "${tmp}" "${USERS_FILE}"
  chmod 0600 "${USERS_FILE}"
}

rewrite_config_users() {
  local tmp label secret
  tmp="$(mktemp)"
  awk '/^\[access\.users\]/{exit} {print}' "${CONFIG_FILE}" > "${tmp}"
  printf '\n[access.users]\n' >> "${tmp}"
  while IFS=$'\t' read -r label secret _; do
    [[ -n "${label}" && -n "${secret}" ]] || continue
    printf '"%s" = "%s"\n' "${label}" "${secret}" >> "${tmp}"
  done < "${USERS_FILE}"
  mv "${tmp}" "${CONFIG_FILE}"
  chown 0:65532 "${CONFIG_FILE}"
  chmod 0640 "${CONFIG_FILE}"
}

link_for() {
  local label="$1" secret
  secret="$(user_secret "${label}")"
  [[ -n "${secret}" ]] || return 1
  printf 'tg://proxy?server=%s&port=%s&secret=dd%s\n' "${PUBLIC_HOST}" "${PORT}" "${secret}"
}

https_link_for() {
  local label="$1" secret
  secret="$(user_secret "${label}")"
  [[ -n "${secret}" ]] || return 1
  printf 'https://t.me/proxy?server=%s&port=%s&secret=dd%s\n' "${PUBLIC_HOST}" "${PORT}" "${secret}"
}

access() {
  local requested="${1:-}" label link found=0
  [[ -f "${USERS_FILE}" ]] || { echo "No proxy users" >&2; return 1; }
  while IFS=$'\t' read -r label _ _; do
    [[ -n "${label}" ]] || continue
    [[ -z "${requested}" || "${requested}" == "${label}" ]] || continue
    found=1
    link="$(link_for "${label}")"
    printf '[%s]\n%s\n%s\n\n' "${label}" "${link}" "$(https_link_for "${label}")"
  done < "${USERS_FILE}"
  [[ "${found}" -eq 1 ]] || { echo "Unknown proxy user: ${requested}" >&2; return 1; }
}

qr() {
  local requested="${1:-}" label link found=0
  [[ -f "${USERS_FILE}" ]] || { echo "No proxy users" >&2; return 1; }
  while IFS=$'\t' read -r label _ _; do
    [[ -n "${label}" ]] || continue
    [[ -z "${requested}" || "${requested}" == "${label}" ]] || continue
    found=1
    link="$(link_for "${label}")"
    printf '[%s]\n%s\n' "${label}" "${link}"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "${link}"
    else
      echo "qrencode is not installed"
    fi
    echo
  done < "${USERS_FILE}"
  [[ "${found}" -eq 1 ]] || { echo "Unknown proxy user: ${requested}" >&2; return 1; }
}

healthcheck() {
  local mode="$1"
  docker exec "${CONTAINER_NAME}" /app/telemt healthcheck /app/config.toml --mode "${mode}"
}

tcp_check() {
  local host="$1" port="$2" label="$3" start end elapsed
  start="$(date +%s%3N 2>/dev/null || date +%s)"
  if timeout 5 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
    end="$(date +%s%3N 2>/dev/null || date +%s)"
    elapsed=$((end - start))
    printf '%-28s ok (%sms)\n' "${label}" "${elapsed}"
    return 0
  fi
  printf '%-28s failed\n' "${label}" >&2
  return 1
}

doctor() {
  local failed=0
  echo "== service =="
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "service: active"
  else
    echo "service: failed"
    failed=1
  fi
  docker inspect -f 'container: {{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${CONTAINER_NAME}" 2>/dev/null \
    || { echo "container: missing"; failed=1; }

  echo
  echo "== Telemt control plane =="
  if healthcheck liveness; then
    echo "liveness: ok"
  else
    echo "liveness: failed"
    failed=1
  fi
  if healthcheck ready; then
    echo "readiness: ok"
  else
    echo "readiness: failed"
    failed=1
  fi

  echo
  echo "== local listener =="
  tcp_check 127.0.0.1 "${PORT}" "local TCP/${PORT}" || failed=1

  echo
  echo "== Telegram Direct-DC probes (informational) =="
  tcp_check 149.154.175.50 443 "Telegram DC1 TCP/443" || true
  tcp_check 149.154.167.51 443 "Telegram DC2 TCP/443" || true
  tcp_check 149.154.175.100 443 "Telegram DC3 TCP/443" || true
  tcp_check 149.154.167.91 443 "Telegram DC4 TCP/443" || true
  tcp_check 91.108.56.183 443 "Telegram DC5 TCP/443" || true

  if [[ "${failed}" -eq 0 ]]; then
    echo
    echo "Doctor: all critical checks passed"
  else
    echo
    echo "Doctor: one or more critical checks failed" >&2
  fi
  return "${failed}"
}

speedtest() {
  echo "== Telegram TCP =="
  tcp_check 149.154.175.50 443 "Telegram DC1 TCP/443" || true
  tcp_check 149.154.167.51 443 "Telegram DC2 TCP/443" || true
  tcp_check 149.154.175.100 443 "Telegram DC3 TCP/443" || true
  tcp_check 149.154.167.91 443 "Telegram DC4 TCP/443" || true
  tcp_check 91.108.56.183 443 "Telegram DC5 TCP/443" || true
  echo
  echo "== HTTPS baseline =="
  curl -L -o /dev/null -sS --max-time 60 \
    -w 'Cloudflare 25 MB: %{speed_download} bytes/s, total %{time_total}s\n' \
    'https://speed.cloudflare.com/__down?bytes=25000000' || true
}

bbr_nat() {
  local cc qdisc src4 public4
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  src4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}' || true)"
  public4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  printf 'tcp_congestion_control: %s\n' "${cc:-unknown}"
  printf 'default_qdisc:          %s\n' "${qdisc:-unknown}"
  printf 'local IPv4 source:      %s\n' "${src4:-unknown}"
  printf 'public IPv4:            %s\n' "${public4:-unknown}"
  echo
  ss -ltnp 2>/dev/null | awk -v port=":${PORT}" '$4 ~ port "$" {print}' || true
}

cmd="${1:-status}"
case "${cmd}" in
  status)
    systemctl status "${SERVICE_NAME}" --no-pager || true
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" || true
    ;;
  logs)
    journalctl -u "${SERVICE_NAME}" -n "${2:-100}" --no-pager
    ;;
  follow)
    journalctl -u "${SERVICE_NAME}" -f
    ;;
  doctor)
    doctor
    ;;
  access)
    access "${2:-}"
    ;;
  qr)
    qr "${2:-}"
    ;;
  users)
    awk -F'\t' 'NF >= 2 {printf "%d) %s  created=%s\n", ++n, $1, $3}' "${USERS_FILE}"
    ;;
  add)
    need_root
    label="${2:-}"
    [[ -n "${label}" ]] || { echo "Usage: mtgctl add LABEL [SECRET]" >&2; exit 1; }
    secret="${3:-$(generate_secret)}"
    upsert_user "${label}" "${secret}"
    rewrite_config_users
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    access "${label}"
    ;;
  revoke)
    need_root
    label="${2:-}"
    [[ -n "${label}" ]] || { echo "Usage: mtgctl revoke LABEL" >&2; exit 1; }
    [[ "$(user_count)" -gt 1 ]] || { echo "Refusing to revoke the last secret" >&2; exit 1; }
    [[ -n "$(user_secret "${label}")" ]] || { echo "Unknown user: ${label}" >&2; exit 1; }
    tmp="$(mktemp)"
    awk -F'\t' -v label="${label}" 'BEGIN{OFS=FS} NF >= 2 && $1 != label {print}' "${USERS_FILE}" > "${tmp}"
    mv "${tmp}" "${USERS_FILE}"
    chmod 0600 "${USERS_FILE}"
    rewrite_config_users
    systemctl restart "${SERVICE_NAME}"
    ;;
  regenerate)
    need_root
    label="${2:-}"
    [[ -n "${label}" ]] || { echo "Usage: mtgctl regenerate LABEL" >&2; exit 1; }
    [[ -n "$(user_secret "${label}")" ]] || { echo "Unknown user: ${label}" >&2; exit 1; }
    upsert_user "${label}" "$(generate_secret)"
    rewrite_config_users
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    access "${label}"
    ;;
  speedtest)
    speedtest
    ;;
  bbr-nat)
    bbr_nat
    ;;
  update)
    need_root
    docker pull "${TELEMT_IMAGE}"
    systemctl restart "${SERVICE_NAME}"
    ;;
  restart|start|stop)
    need_root
    systemctl "${cmd}" "${SERVICE_NAME}"
    ;;
  uninstall)
    need_root
    systemctl disable --now "${SERVICE_NAME}" || true
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_FILE}" "${CONTROL_BIN}"
    systemctl daemon-reload
    if [[ "${2:-}" == "--purge" ]]; then
      rm -rf "${CONFIG_DIR}"
      echo "Removed service, container and ${CONFIG_DIR}"
    else
      echo "Removed service and container; configuration kept in ${CONFIG_DIR}"
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
CONTROL_EOF
  chmod 0755 "${CONTROL_BIN}"
}

stop_conflicting_services() {
  if systemctl list-unit-files "${SERVICE_NAME}" >/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1; then
    if systemctl is-active --quiet "${LEGACY_SERVICE_NAME}" || systemctl is-enabled --quiet "${LEGACY_SERVICE_NAME}" 2>/dev/null; then
      warn "Disabling legacy ${LEGACY_SERVICE_NAME}; /etc/mtg is kept as a backup"
      systemctl disable --now "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
  fi

  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${LEGACY_CONTAINER_NAME}" >/dev/null 2>&1 || true
  if docker inspect "${ALTERNATE_CONTAINER_NAME}" >/dev/null 2>&1; then
    warn "Stopping alternate ${ALTERNATE_CONTAINER_NAME} container; it is kept for rollback"
    docker stop "${ALTERNATE_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

check_port_available() {
  local listeners
  listeners="$(ss -ltnp 2>/dev/null | awk -v port=":${PORT}" '$4 ~ port "$" {print}' || true)"
  if [[ -n "${listeners}" ]]; then
    printf '%s\n' "${listeners}" >&2
    die "TCP/${PORT} is already occupied by another process"
  fi
}

configure_firewall() {
  [[ "${CONFIGURE_FIREWALL}" -eq 1 ]] || { warn "Firewall changes skipped"; return; }
  log "Configuring firewall for TCP/${PORT}"
  if cmd_exists ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${PORT}/tcp" comment "clean MTProto proxy"
    return
  fi
  if cmd_exists firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --add-port="${PORT}/tcp" --permanent
    firewall-cmd --reload
    return
  fi
  if [[ "${IPTABLES_FALLBACK}" -eq 1 ]] && cmd_exists iptables; then
    if ! iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT
    fi
    warn "Added a non-persistent iptables rule"
    return
  fi
  warn "No active ufw/firewalld found. Open TCP/${PORT} in the VPS provider firewall."
}

pull_image() {
  log "Pulling ${TELEMT_IMAGE}"
  docker pull "${TELEMT_IMAGE}"
}

start_service() {
  [[ "${START_SERVICE}" -eq 1 ]] || { warn "Service start skipped"; return; }
  log "Starting ${SERVICE_NAME}"
  systemctl enable --now "${SERVICE_NAME}"
  sleep 3
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 100 --no-pager || true
    die "${SERVICE_NAME} did not start"
  fi
}

wait_ready() {
  [[ "${START_SERVICE}" -eq 1 ]] || return 0
  for _ in {1..30}; do
    if docker exec "${CONTAINER_NAME}" /app/telemt healthcheck /app/config.toml --mode ready >/dev/null 2>&1; then
      log "Telemt is ready to relay Telegram traffic"
      return 0
    fi
    sleep 1
  done
  docker logs --tail 100 "${CONTAINER_NAME}" 2>/dev/null || true
  return 1
}

run_doctor() {
  [[ "${RUN_DOCTOR}" -eq 1 && "${START_SERVICE}" -eq 1 ]] || return
  log "Running end-to-end readiness checks"
  if "${CONTROL_BIN}" doctor; then
    return
  fi
  if [[ "${STRICT_DOCTOR}" -eq 1 ]]; then
    die "Proxy is not ready; installation stopped before reporting success"
  fi
  warn "Doctor reported a problem"
}

run_optional_checks() {
  if [[ "${RUN_BBR_NAT_CHECK}" -eq 1 ]]; then
    "${CONTROL_BIN}" bbr-nat || true
  fi
  if [[ "${RUN_SPEEDTEST}" -eq 1 ]]; then
    "${CONTROL_BIN}" speedtest || true
  fi
}

show_access() {
  [[ "${START_SERVICE}" -eq 1 ]] || return
  log "Proxy links"
  "${CONTROL_BIN}" access
}

install_proxy() {
  install_packages
  ensure_docker
  ensure_public_host
  validate_input
  [[ "${LEGACY_OPTIONS_USED}" -eq 0 ]] || warn "Legacy FakeTLS options were ignored; secure mode uses no domain or Nginx"
  pull_image
  stop_conflicting_services
  check_port_available
  ensure_initial_user
  write_config
  write_state
  write_systemd_unit
  write_control_script
  configure_firewall
  start_service
  if [[ "${RUN_DOCTOR}" -eq 1 && "${START_SERVICE}" -eq 1 ]]; then
    if ! wait_ready; then
      if [[ "${STRICT_DOCTOR}" -eq 1 ]]; then
        die "Telemt did not become ready; inspect: sudo journalctl -u ${SERVICE_NAME} -n 100"
      fi
      warn "Telemt readiness timed out"
    fi
  fi
  run_doctor
  show_access
  run_optional_checks
  cat <<EOF

Installed successfully.

  Service: ${SERVICE_NAME}
  Config:  ${CONFIG_FILE}
  Helper:  ${CONTROL_BIN}

Useful commands:
  sudo mtgctl status
  sudo mtgctl doctor
  sudo mtgctl access
  sudo mtgctl qr
  sudo mtgctl logs

The old FakeTLS links are intentionally invalid after migration. Add the new
dd link shown above to Telegram and remove the old proxy entry.
EOF
}

prompt_value() {
  local label="$1" variable="$2" default_value="$3" value
  read -r -p "${label} [${default_value}]: " value
  printf -v "${variable}" '%s' "${value:-${default_value}}"
}

prompt_yes_no() {
  local label="$1" default_value="$2" answer
  if [[ "${default_value}" -eq 1 ]]; then
    read -r -p "${label} [Y/n]: " answer
    [[ ! "${answer}" =~ ^([Nn]|[Nn][Oo])$ ]]
  else
    read -r -p "${label} [y/N]: " answer
    [[ "${answer}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
  fi
}

prompt_install_settings() {
  load_state
  prompt_value "Public port" PORT "${PORT:-443}"
  prompt_value "Public IP or DNS (empty = auto-detect)" PUBLIC_HOST "${PUBLIC_HOST:-}"
  prompt_value "Telemt image tag" TELEMT_TAG "${TELEMT_TAG:-3.4.23}"
  TELEMT_IMAGE="ghcr.io/telemt/telemt:${TELEMT_TAG}"
  if prompt_yes_no "Use Telegram Middle-End with Direct-DC fallback" "${USE_MIDDLE_PROXY:-1}"; then
    USE_MIDDLE_PROXY=1
  else
    USE_MIDDLE_PROXY=0
  fi
  if prompt_yes_no "Prefer IPv6 upstreams" "${PREFER_IPV6:-0}"; then
    PREFER_IPV6=1
  else
    PREFER_IPV6=0
  fi
}

proxy_is_installed() {
  [[ -f "${STATE_FILE}" && -f "${CONFIG_FILE}" && -x "${CONTROL_BIN}" ]]
}

menu_add_user() {
  local label secret
  proxy_is_installed || { warn "Install the proxy first"; return; }
  load_state
  prompt_value "New user label" label "family"
  validate_label "${label}"
  read -r -p "32-hex secret (empty = generate): " secret
  [[ -n "${secret}" ]] || secret="$(generate_secret)"
  upsert_user "${label}" "${secret}"
  ensure_public_host
  write_config
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  "${CONTROL_BIN}" access "${label}"
}

menu_revoke_user() {
  local label
  proxy_is_installed || { warn "Install the proxy first"; return; }
  load_state
  [[ "$(user_count)" -gt 1 ]] || { warn "The last secret cannot be revoked"; return; }
  label="$(select_user_label)"
  remove_user "${label}"
  write_config
  systemctl restart "${SERVICE_NAME}"
  log "Revoked ${label}"
}

menu_regenerate_user() {
  local label
  proxy_is_installed || { warn "Install the proxy first"; return; }
  load_state
  label="$(select_user_label)"
  upsert_user "${label}" "$(generate_secret)"
  write_config
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  "${CONTROL_BIN}" access "${label}"
}

installer_uninstall() {
  local purge=0 answer
  read -r -p "Remove ${CONFIG_DIR} too? [y/N]: " answer
  [[ "${answer}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] && purge=1
  systemctl disable --now "${SERVICE_NAME}" || true
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_FILE}" "${CONTROL_BIN}"
  systemctl daemon-reload
  [[ "${purge}" -eq 0 ]] || rm -rf "${CONFIG_DIR}"
  log "Proxy removed"
}

run_control_or_warn() {
  if [[ -x "${CONTROL_BIN}" ]]; then
    "${CONTROL_BIN}" "$@"
  else
    warn "Proxy is not installed"
  fi
}

menu_loop() {
  local choice
  while true; do
    clear || true
    cat <<'EOF'
Clean MTProto Proxy

1) Install / update proxy
2) Show status
3) Show proxy links + QR
4) Show logs
5) Run doctor
6) Add secret
7) Revoke secret
8) Regenerate secret
9) Run speed test
10) Run BBR/NAT diagnostics
11) Restart proxy
12) Update container image
13) Remove proxy
0) Exit
EOF
    read -r -p "Choose option: " choice
    case "${choice}" in
      1) prompt_install_settings; install_proxy; pause ;;
      2) run_control_or_warn status; pause ;;
      3) run_control_or_warn qr; pause ;;
      4) run_control_or_warn logs; pause ;;
      5) run_control_or_warn doctor; pause ;;
      6) menu_add_user; pause ;;
      7) menu_revoke_user; pause ;;
      8) menu_regenerate_user; pause ;;
      9) run_control_or_warn speedtest; pause ;;
      10) run_control_or_warn bbr-nat; pause ;;
      11) run_control_or_warn restart; pause ;;
      12) run_control_or_warn update; pause ;;
      13) installer_uninstall; pause ;;
      0) exit 0 ;;
      *) warn "Unknown option"; pause ;;
    esac
  done
}

main() {
  if [[ "$#" -eq 0 && -t 0 && -t 1 ]]; then
    require_root
    menu_loop
  fi

  if [[ -f "${STATE_FILE}" ]]; then
    load_state
  fi
  parse_args "$@"
  require_root
  validate_input
  install_proxy
}

if [[ "${CLEAN_MTG_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
