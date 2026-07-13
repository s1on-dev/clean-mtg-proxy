#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="mtg.service"
CONTAINER_NAME="mtg-proxy"
CONFIG_DIR="/etc/mtg"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
STATE_FILE="${CONFIG_DIR}/install.env"
SECRETS_FILE="${CONFIG_DIR}/secrets.tsv"
ALLOWLIST_FILE="${CONFIG_DIR}/allowlist.netset"
SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}"
CONTROL_BIN="/usr/local/bin/mtgctl"
NGINX_SITE_FILE="/etc/nginx/conf.d/mtg-disguise.conf"
NGINX_WEB_ROOT="/var/www/mtg-disguise"

DOMAIN="${DOMAIN:-}"
PORT="${PORT:-443}"
SECRET="${SECRET:-}"
ACTIVE_SECRET_LABEL="${ACTIVE_SECRET_LABEL:-default}"
MTG_TAG="${MTG_TAG:-2.2.8}"
PREFER_IP="${PREFER_IP:-prefer-ipv4}"
CONCURRENCY="${CONCURRENCY:-8192}"
DNS_RESOLVER="${DNS_RESOLVER:-https://1.1.1.1}"
BLOCKLIST_URL="${BLOCKLIST_URL:-https://iplists.firehol.org/files/firehol_abusers_1d.netset}"
ENABLE_ALLOWLIST="${ENABLE_ALLOWLIST:-0}"
ALLOWLIST_CIDRS="${ALLOWLIST_CIDRS:-}"
ENABLE_NGINX_DISGUISE="${ENABLE_NGINX_DISGUISE:-0}"
DISGUISE_SERVER_NAME="${DISGUISE_SERVER_NAME:-_}"
DISGUISE_HTTP_PORT="${DISGUISE_HTTP_PORT:-80}"

INSTALL_DOCKER=1
ALLOW_DOCKER_SCRIPT=1
CONFIGURE_FIREWALL=1
IPTABLES_FALLBACK=0
RUN_DOCTOR=1
STRICT_DOCTOR=0
RUN_SPEEDTEST=1
RUN_BBR_NAT_CHECK=0
START_SERVICE=1
BASE_PACKAGES_READY=0

usage() {
  cat <<'EOF'
Clean mtg MTProto proxy installer.

Usage:
  sudo bash install.sh
  sudo bash install.sh --domain example.com [options]

Required:
  --domain DOMAIN          FakeTLS/domain-fronting hostname used to generate secret.
                           Choose a domain thoughtfully. For non-interactive
                           installs this option is required.

Options:
  --port PORT              Public TCP port, default: 443
  --secret SECRET          Existing mtg secret. If omitted, it is generated.
  --secret-label LABEL     Label for the active saved secret, default: default
  --tag TAG                Docker image tag for nineseconds/mtg, default: 2.2.8
  --prefer-ip MODE         prefer-ipv4, prefer-ipv6, only-ipv4, only-ipv6
  --concurrency N          Max client connections, default: 8192
  --dns URL                Resolver for mtg, default: https://1.1.1.1
  --blocklist URL          FireHOL-compatible blocklist URL
  --allowlist CIDRS        Enable mtg allowlist. CIDRs may be comma or space separated.
  --nginx-disguise         Install a quiet Nginx HTTP decoy site
  --disguise-server-name N Server name for Nginx decoy, default: _
  --disguise-port PORT     HTTP port for Nginx decoy, default: 80
  --bbr-nat-check          Run optional BBR/NAT diagnostics after install
  --skip-docker-install    Require Docker to be already installed
  --no-docker-script       Do not fallback to https://get.docker.com
  --skip-firewall          Do not open firewall port
  --iptables-fallback      If ufw/firewalld are absent, add a non-persistent
                           iptables ACCEPT rule for the proxy port
  --skip-doctor            Do not run mtg doctor during installation
  --strict-doctor          Fail installation if mtg doctor reports problems
  --skip-speedtest         Do not run basic connectivity/speed test
  --no-start               Write files but do not start the service
  -h, --help               Show help

Examples:
  sudo bash install.sh
  sudo bash install.sh --domain digitalocean.com
  sudo DOMAIN=digitalocean.com bash install.sh
  curl -fsSL https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh \
    | sudo bash -s -- --domain digitalocean.com --port 443
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

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}" || true
  fi
}

current_secret() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  awk -F'"' '/^secret[[:space:]]*=/{print $2; exit}' "${CONFIG_FILE}" 2>/dev/null || true
}

prompt_yes_no() {
  local label default_value answer
  label="$1"
  default_value="$2"

  if [[ "${default_value}" == "1" ]]; then
    read -r -p "${label} [Y/n]: " answer
    case "${answer}" in
      n|N|no|NO|No) return 1 ;;
      *) return 0 ;;
    esac
  fi

  read -r -p "${label} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_value() {
  local label var_name default_value input
  label="$1"
  var_name="$2"
  default_value="$3"

  read -r -p "${label} [${default_value}]: " input
  printf -v "${var_name}" '%s' "${input:-${default_value}}"
}

prompt_prefer_ip() {
  local input

  cat <<EOF
IP mode:
  1) prefer-ipv4 (recommended for most VPS)
  2) prefer-ipv6
  3) only-ipv4
  4) only-ipv6
EOF
  read -r -p "Choose IP mode [${PREFER_IP}]: " input

  case "${input}" in
    1) PREFER_IP="prefer-ipv4" ;;
    2) PREFER_IP="prefer-ipv6" ;;
    3) PREFER_IP="only-ipv4" ;;
    4) PREFER_IP="only-ipv6" ;;
    "") ;;
    prefer-ipv4|prefer-ipv6|only-ipv4|only-ipv6) PREFER_IP="${input}" ;;
    *) warn "Unknown IP mode, keeping ${PREFER_IP}" ;;
  esac
}

validate_secret_label() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "Secret label may contain only letters, numbers, dot, underscore and dash"
}

secret_store_init() {
  local existing_secret now

  mkdir -p "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"

  if [[ ! -f "${SECRETS_FILE}" ]]; then
    existing_secret="$(current_secret)"
    if [[ -n "${existing_secret}" ]]; then
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\t%s\t%s\t%s\n' "${ACTIVE_SECRET_LABEL:-default}" "${DOMAIN:-unknown}" "${existing_secret}" "${now}" > "${SECRETS_FILE}"
    else
      : > "${SECRETS_FILE}"
    fi
  fi

  chmod 0600 "${SECRETS_FILE}"
}

store_secret() {
  local label domain secret now tmp
  label="$1"
  domain="$2"
  secret="$3"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  validate_secret_label "${label}"
  [[ -n "${domain}" ]] || die "Secret domain is empty"
  [[ -n "${secret}" ]] || die "Secret value is empty"

  secret_store_init
  tmp="$(mktemp)"
  awk -F'\t' -v label="${label}" 'BEGIN { OFS = FS } $1 != label { print }' "${SECRETS_FILE}" > "${tmp}"
  printf '%s\t%s\t%s\t%s\n' "${label}" "${domain}" "${secret}" "${now}" >> "${tmp}"
  mv "${tmp}" "${SECRETS_FILE}"
  chmod 0600 "${SECRETS_FILE}"
}

remove_secret() {
  local label tmp
  label="$1"
  secret_store_init
  tmp="$(mktemp)"
  awk -F'\t' -v label="${label}" 'BEGIN { OFS = FS } $1 != label { print }' "${SECRETS_FILE}" > "${tmp}"
  mv "${tmp}" "${SECRETS_FILE}"
  chmod 0600 "${SECRETS_FILE}"
}

secret_count() {
  secret_store_init
  awk -F'\t' 'NF >= 3 { count++ } END { print count + 0 }' "${SECRETS_FILE}"
}

print_secret_list() {
  local active
  active="${ACTIVE_SECRET_LABEL:-default}"
  secret_store_init
  awk -F'\t' -v active="${active}" 'NF >= 3 {
    marker = ($1 == active) ? "*" : " ";
    printf "%s %d) %s  domain=%s  created=%s\n", marker, ++i, $1, $2, $4
  }
  END {
    if (i == 0) {
      print "No saved secrets yet."
    }
  }' "${SECRETS_FILE}"
}

select_secret_from_store() {
  local rows_count choice row
  secret_store_init
  rows_count="$(secret_count)"
  [[ "${rows_count}" -gt 0 ]] || die "No saved secrets"

  print_secret_list
  read -r -p "Choose saved secret number: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid secret number"
  (( choice >= 1 && choice <= rows_count )) || die "Secret number is out of range"

  row="$(awk -F'\t' -v n="${choice}" 'NF >= 3 { i++; if (i == n) { print; exit } }' "${SECRETS_FILE}")"
  IFS=$'\t' read -r ACTIVE_SECRET_LABEL DOMAIN SECRET _ <<< "${row}"
  [[ -n "${ACTIVE_SECRET_LABEL}" && -n "${DOMAIN}" && -n "${SECRET}" ]] || die "Saved secret entry is invalid"
}

print_settings() {
  cat <<EOF

Current settings:
  Domain:      ${DOMAIN:-not set}
  Port:        ${PORT}
  Secret:      ${ACTIVE_SECRET_LABEL:-default}
  Image tag:   ${MTG_TAG}
  IP mode:     ${PREFER_IP}
  Concurrency: ${CONCURRENCY}
  DNS:         ${DNS_RESOLVER}
  Blocklist:   ${BLOCKLIST_URL}
  Allowlist:   ${ENABLE_ALLOWLIST} ${ALLOWLIST_CIDRS}
  Nginx decoy: ${ENABLE_NGINX_DISGUISE} port=${DISGUISE_HTTP_PORT}
EOF
}

prompt_install_settings() {
  local old_domain old_secret regenerate

  load_state
  old_domain="${DOMAIN:-}"
  old_secret="$(current_secret)"

  print_settings
  echo
  prompt_value "FakeTLS domain" DOMAIN "${DOMAIN:-digitalocean.com}"
  prompt_value "Public port" PORT "${PORT:-443}"
  prompt_value "Docker image tag" MTG_TAG "${MTG_TAG:-2.2.8}"
  prompt_prefer_ip
  prompt_value "Max connections" CONCURRENCY "${CONCURRENCY:-8192}"
  prompt_value "DNS resolver" DNS_RESOLVER "${DNS_RESOLVER:-https://1.1.1.1}"
  prompt_value "Blocklist URL" BLOCKLIST_URL "${BLOCKLIST_URL:-https://iplists.firehol.org/files/firehol_abusers_1d.netset}"
  prompt_value "Active secret label" ACTIVE_SECRET_LABEL "${ACTIVE_SECRET_LABEL:-default}"

  if prompt_yes_no "Enable mtg IP allowlist profile" "${ENABLE_ALLOWLIST:-0}"; then
    ENABLE_ALLOWLIST=1
    prompt_value "Allowed client CIDRs, comma or space separated" ALLOWLIST_CIDRS "${ALLOWLIST_CIDRS:-}"
  else
    ENABLE_ALLOWLIST=0
  fi

  if prompt_yes_no "Enable Nginx HTTP disguise profile" "${ENABLE_NGINX_DISGUISE:-0}"; then
    ENABLE_NGINX_DISGUISE=1
    prompt_value "Nginx server_name" DISGUISE_SERVER_NAME "${DISGUISE_SERVER_NAME:-_}"
    prompt_value "Nginx HTTP port" DISGUISE_HTTP_PORT "${DISGUISE_HTTP_PORT:-80}"
  else
    ENABLE_NGINX_DISGUISE=0
  fi

  if prompt_yes_no "Run BBR/NAT diagnostics after install" "${RUN_BBR_NAT_CHECK:-0}"; then
    RUN_BBR_NAT_CHECK=1
  else
    RUN_BBR_NAT_CHECK=0
  fi

  SECRET=""
  if [[ -n "${old_secret}" ]]; then
    if [[ "${DOMAIN}" == "${old_domain}" ]]; then
      read -r -p "Keep existing proxy secret? [Y/n]: " regenerate
      case "${regenerate}" in
        n|N|no|NO|No) SECRET="" ;;
        *) SECRET="${old_secret}" ;;
      esac
    else
      read -r -p "Domain changed. Generate a new secret for ${DOMAIN}? [Y/n]: " regenerate
      case "${regenerate}" in
        n|N|no|NO|No) SECRET="${old_secret}" ;;
        *) SECRET="" ;;
      esac
    fi
  fi
}

installer_uninstall() {
  local purge_answer purge

  purge=0
  read -r -p "Remove /etc/mtg config too? [y/N]: " purge_answer
  case "${purge_answer}" in
    y|Y|yes|YES|Yes) purge=1 ;;
  esac

  log "Removing ${SERVICE_NAME}"
  systemctl disable --now "${SERVICE_NAME}" || true
  if cmd_exists docker; then
    docker rm -f "${CONTAINER_NAME}" || true
  fi
  rm -f "${SYSTEMD_FILE}" "${CONTROL_BIN}"
  systemctl daemon-reload

  if [[ "${purge}" -eq 1 ]]; then
    rm -rf "${CONFIG_DIR}"
    log "Removed service, container and ${CONFIG_DIR}"
  else
    log "Removed service and container. Config kept in ${CONFIG_DIR}"
  fi
}

menu_access() {
  if [[ -x "${CONTROL_BIN}" ]]; then
    "${CONTROL_BIN}" access || true
  elif cmd_exists docker && [[ -f "${CONFIG_FILE}" ]]; then
    load_state
    docker run --rm -v "${CONFIG_FILE}:/config.toml:ro" "nineseconds/mtg:${MTG_TAG}" access /config.toml || true
  else
    warn "Proxy is not installed yet. Use menu option 1 first."
  fi
}

menu_status() {
  systemctl status "${SERVICE_NAME}" --no-pager || true
  if cmd_exists docker; then
    docker ps --filter "name=${CONTAINER_NAME}" || true
  fi
}

menu_logs() {
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager || true
}

menu_doctor_speedtest() {
  if [[ -x "${CONTROL_BIN}" ]]; then
    "${CONTROL_BIN}" doctor || true
    echo
    "${CONTROL_BIN}" speedtest || true
  else
    warn "Proxy is not installed yet. Use menu option 1 first."
  fi
}

menu_restart() {
  if systemctl restart "${SERVICE_NAME}"; then
    systemctl status "${SERVICE_NAME}" --no-pager || true
  else
    warn "Could not restart ${SERVICE_NAME}. Is the proxy installed?"
  fi
}

reload_proxy_config() {
  local installed_secret

  installed_secret="$(current_secret)"
  SECRET="${SECRET:-${installed_secret}}"
  [[ -n "${SECRET}" ]] || die "No active secret found. Install the proxy first."

  validate_input
  write_config
  write_systemd_unit
  write_control_script
  configure_nginx_disguise

  if systemctl list-unit-files "${SERVICE_NAME}" >/dev/null 2>&1; then
    systemctl restart "${SERVICE_NAME}" || die "Could not restart ${SERVICE_NAME}"
  fi

  run_doctor
  show_access
}

menu_bbr_nat_check() {
  if [[ -x "${CONTROL_BIN}" ]]; then
    "${CONTROL_BIN}" bbr-nat || true
  else
    bbr_nat_check || true
  fi
}

menu_secret_add_switch() {
  local choice label domain imported

  load_state
  ensure_docker
  secret_store_init

  cat <<EOF
Secret management

mtg v2 supports one active secret. This menu keeps saved secrets and switches
which one is active in /etc/mtg/config.toml.

1) Generate/import a new saved secret
2) Switch to an existing saved secret
0) Back
EOF
  read -r -p "Choose option: " choice

  case "${choice}" in
    1)
      prompt_value "Secret label" label "default"
      validate_secret_label "${label}"
      prompt_value "FakeTLS domain for this secret" domain "${DOMAIN:-digitalocean.com}"
      read -r -p "Paste existing secret or leave empty to generate: " imported

      DOMAIN="${domain}"
      if [[ -n "${imported}" ]]; then
        SECRET="${imported}"
      else
        SECRET="$(generate_secret_for_domain "${DOMAIN}")"
      fi

      store_secret "${label}" "${DOMAIN}" "${SECRET}"

      if prompt_yes_no "Make this secret active now" 1; then
        ACTIVE_SECRET_LABEL="${label}"
        reload_proxy_config
      else
        log "Saved secret '${label}'. It is not active yet."
      fi
      ;;
    2)
      select_secret_from_store
      reload_proxy_config
      ;;
    0|"")
      return
      ;;
    *)
      warn "Unknown secret menu option"
      ;;
  esac
}

menu_secret_revoke() {
  local rows_count choice row label was_active

  load_state
  secret_store_init
  rows_count="$(secret_count)"
  [[ "${rows_count}" -gt 0 ]] || {
    warn "No saved secrets to revoke"
    return
  }

  print_secret_list
  read -r -p "Choose secret number to revoke: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid secret number"
  (( choice >= 1 && choice <= rows_count )) || die "Secret number is out of range"

  row="$(awk -F'\t' -v n="${choice}" 'NF >= 3 { i++; if (i == n) { print; exit } }' "${SECRETS_FILE}")"
  IFS=$'\t' read -r label _ _ _ <<< "${row}"
  was_active=0
  [[ "${label}" == "${ACTIVE_SECRET_LABEL:-default}" ]] && was_active=1

  remove_secret "${label}"
  log "Revoked saved secret '${label}'"

  if [[ "${was_active}" -eq 1 ]]; then
    if [[ "$(secret_count)" -gt 0 ]]; then
      warn "You revoked the active secret. Choose a replacement."
      select_secret_from_store
      reload_proxy_config
    else
      warn "No saved secrets left. Generate a replacement now."
      SECRET=""
      prompt_value "FakeTLS domain" DOMAIN "${DOMAIN:-digitalocean.com}"
      SECRET="$(generate_secret_for_domain "${DOMAIN}")"
      ACTIVE_SECRET_LABEL="default"
      store_secret "${ACTIVE_SECRET_LABEL}" "${DOMAIN}" "${SECRET}"
      reload_proxy_config
    fi
  fi
}

menu_secret_regenerate() {
  load_state
  ensure_docker
  prompt_value "FakeTLS domain" DOMAIN "${DOMAIN:-digitalocean.com}"
  prompt_value "Active secret label" ACTIVE_SECRET_LABEL "${ACTIVE_SECRET_LABEL:-default}"
  SECRET="$(generate_secret_for_domain "${DOMAIN}")"
  store_secret "${ACTIVE_SECRET_LABEL}" "${DOMAIN}" "${SECRET}"
  reload_proxy_config
}

menu_profiles() {
  load_state
  SECRET="$(current_secret)"
  [[ -n "${SECRET}" ]] || {
    warn "Proxy is not installed yet. Use menu option 1 first."
    return
  }

  if prompt_yes_no "Enable mtg IP allowlist profile" "${ENABLE_ALLOWLIST:-0}"; then
    ENABLE_ALLOWLIST=1
    prompt_value "Allowed client CIDRs, comma or space separated" ALLOWLIST_CIDRS "${ALLOWLIST_CIDRS:-}"
  else
    ENABLE_ALLOWLIST=0
  fi

  if prompt_yes_no "Enable Nginx HTTP disguise profile" "${ENABLE_NGINX_DISGUISE:-0}"; then
    ENABLE_NGINX_DISGUISE=1
    prompt_value "Nginx server_name" DISGUISE_SERVER_NAME "${DISGUISE_SERVER_NAME:-_}"
    prompt_value "Nginx HTTP port" DISGUISE_HTTP_PORT "${DISGUISE_HTTP_PORT:-80}"
  else
    ENABLE_NGINX_DISGUISE=0
  fi

  reload_proxy_config
}

menu_loop() {
  local choice

  while true; do
    clear || true
    load_state
    cat <<EOF
Clean MTG Proxy Installer

1) Install / update proxy
2) Change settings and reinstall
3) Show proxy link
4) Show status
5) Show logs
6) Run mtg doctor + speedtest
7) Run BBR/NAT diagnostics
8) Add / switch secret
9) Revoke secret
10) Regenerate active secret
11) Configure Nginx disguise / allowlist
12) Restart proxy
13) Remove proxy
0) Exit
EOF
    echo
    read -r -p "Choose option: " choice

    case "${choice}" in
      1|2)
        prompt_install_settings
        validate_input
        install_proxy
        pause
        ;;
      3)
        menu_access
        pause
        ;;
      4)
        menu_status
        pause
        ;;
      5)
        menu_logs
        pause
        ;;
      6)
        menu_doctor_speedtest
        pause
        ;;
      7)
        menu_bbr_nat_check
        pause
        ;;
      8)
        menu_secret_add_switch
        pause
        ;;
      9)
        menu_secret_revoke
        pause
        ;;
      10)
        menu_secret_regenerate
        pause
        ;;
      11)
        menu_profiles
        pause
        ;;
      12)
        menu_restart
        pause
        ;;
      13)
        installer_uninstall
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Unknown menu option"
        pause
        ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"; shift 2 ;;
      --port)
        PORT="${2:-}"; shift 2 ;;
      --secret)
        SECRET="${2:-}"; shift 2 ;;
      --secret-label)
        ACTIVE_SECRET_LABEL="${2:-}"; shift 2 ;;
      --tag)
        MTG_TAG="${2:-}"; shift 2 ;;
      --prefer-ip)
        PREFER_IP="${2:-}"; shift 2 ;;
      --concurrency)
        CONCURRENCY="${2:-}"; shift 2 ;;
      --dns)
        DNS_RESOLVER="${2:-}"; shift 2 ;;
      --blocklist)
        BLOCKLIST_URL="${2:-}"; shift 2 ;;
      --allowlist)
        ENABLE_ALLOWLIST=1; ALLOWLIST_CIDRS="${2:-}"; shift 2 ;;
      --nginx-disguise)
        ENABLE_NGINX_DISGUISE=1; shift ;;
      --disguise-server-name)
        DISGUISE_SERVER_NAME="${2:-}"; shift 2 ;;
      --disguise-port)
        DISGUISE_HTTP_PORT="${2:-}"; shift 2 ;;
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
      --skip-speedtest)
        RUN_SPEEDTEST=0; shift ;;
      --no-start)
        START_SERVICE=0; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash install.sh"
  fi

  if ! cmd_exists systemctl; then
    die "systemd is required. This installer targets ordinary Linux VPS images."
  fi
}

normalize_allowlist_cidrs() {
  printf '%s\n' "${ALLOWLIST_CIDRS}" | tr ',; ' '\n' | awk 'NF { print }'
}

validate_input() {
  if [[ -z "${DOMAIN}" && -t 0 ]]; then
    read -r -p "FakeTLS domain, for example digitalocean.com: " DOMAIN
  fi

  [[ -n "${DOMAIN}" ]] || die "Missing --domain. Example: --domain digitalocean.com"
  [[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Domain contains unsupported characters: ${DOMAIN}"
  [[ "${DOMAIN}" != .* && "${DOMAIN}" != *..* && "${DOMAIN}" == *.* ]] || die "Domain looks invalid: ${DOMAIN}"

  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be a number"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535"

  [[ "${DISGUISE_HTTP_PORT}" =~ ^[0-9]+$ ]] || die "Disguise port must be a number"
  (( DISGUISE_HTTP_PORT >= 1 && DISGUISE_HTTP_PORT <= 65535 )) || die "Disguise port must be between 1 and 65535"
  if [[ "${ENABLE_NGINX_DISGUISE}" -eq 1 && "${DISGUISE_HTTP_PORT}" == "${PORT}" ]]; then
    die "Nginx disguise port must be different from the MTProto proxy port"
  fi

  [[ "${CONCURRENCY}" =~ ^[0-9]+$ ]] || die "Concurrency must be a number"
  (( CONCURRENCY >= 1 )) || die "Concurrency must be greater than zero"

  [[ "${MTG_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Docker tag contains unsupported characters: ${MTG_TAG}"
  validate_secret_label "${ACTIVE_SECRET_LABEL:-default}"

  [[ "${DNS_RESOLVER}" != *\"* && "${DNS_RESOLVER}" != *\\* ]] || die "DNS resolver contains unsupported characters"
  [[ "${BLOCKLIST_URL}" != *\"* && "${BLOCKLIST_URL}" != *\\* ]] || die "Blocklist URL contains unsupported characters"
  [[ "${SECRET}" != *\"* && "${SECRET}" != *\\* ]] || die "Secret contains unsupported characters"
  [[ "${ALLOWLIST_CIDRS}" != *\"* && "${ALLOWLIST_CIDRS}" != *\\* && "${ALLOWLIST_CIDRS}" != *"'"* ]] || die "Allowlist contains unsupported characters"
  [[ "${DISGUISE_SERVER_NAME}" != *\"* && "${DISGUISE_SERVER_NAME}" != *\\* && "${DISGUISE_SERVER_NAME}" != *"'"* ]] || die "Disguise server name contains unsupported characters"

  case "${PREFER_IP}" in
    prefer-ipv4|prefer-ipv6|only-ipv4|only-ipv6) ;;
    *) die "Unsupported --prefer-ip value: ${PREFER_IP}" ;;
  esac

  if [[ "${ENABLE_ALLOWLIST}" -eq 1 ]]; then
    [[ -n "$(normalize_allowlist_cidrs)" ]] || die "--allowlist requires at least one CIDR"
    while IFS= read -r cidr; do
      [[ "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || "${cidr}" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
        || die "Allowlist entry is not a CIDR: ${cidr}"
    done < <(normalize_allowlist_cidrs)
  fi
}

detect_pkg_manager() {
  if cmd_exists apt-get; then
    echo "apt"
  elif cmd_exists dnf; then
    echo "dnf"
  elif cmd_exists yum; then
    echo "yum"
  else
    echo "unknown"
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
      warn "Unknown package manager. I will continue and rely on existing tools."
      ;;
  esac

  BASE_PACKAGES_READY=1
}

install_docker_from_packages() {
  local pm
  pm="$(detect_pkg_manager)"

  case "${pm}" in
    apt)
      apt-get install -y docker.io
      ;;
    dnf)
      dnf install -y moby-engine || dnf install -y docker
      ;;
    yum)
      yum install -y moby-engine || yum install -y docker
      ;;
    *)
      return 1
      ;;
  esac
}

install_docker_official_script() {
  [[ "${ALLOW_DOCKER_SCRIPT}" -eq 1 ]] || return 1
  cmd_exists curl || return 1

  warn "Falling back to Docker's official convenience script: https://get.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
}

ensure_docker() {
  if cmd_exists docker; then
    log "Docker is already installed"
  else
    [[ "${INSTALL_DOCKER}" -eq 1 ]] || die "Docker is not installed and --skip-docker-install was used"
    install_packages
    log "Installing Docker"
    install_docker_from_packages || install_docker_official_script || die "Docker installation failed"
  fi

  systemctl enable --now docker
  cmd_exists docker || die "Docker binary is still unavailable"
  docker info >/dev/null || die "Docker daemon is not responding"
}

confirm_overwrite() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    local backup
    backup="${CONFIG_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${CONFIG_FILE}" "${backup}"
    warn "Existing config backed up to ${backup}"
  fi
}

generate_secret_for_domain() {
  local secret_domain generated_secret
  secret_domain="$1"

  docker pull "nineseconds/mtg:${MTG_TAG}" >/dev/null
  generated_secret="$(docker run --rm "nineseconds/mtg:${MTG_TAG}" generate-secret --hex "${secret_domain}" | tr -d '\r\n ')"
  [[ -n "${generated_secret}" ]] || die "Could not generate secret"
  printf '%s\n' "${generated_secret}"
}

generate_secret() {
  if [[ -n "${SECRET}" ]]; then
    log "Using provided secret"
    return
  fi

  log "Generating FakeTLS secret for ${DOMAIN}"
  SECRET="$(generate_secret_for_domain "${DOMAIN}")"
  [[ -n "${SECRET}" ]] || die "Could not generate secret"
}

write_allowlist_file() {
  log "Writing ${ALLOWLIST_FILE}"
  mkdir -p "${CONFIG_DIR}"
  {
    echo "# clean-mtg-proxy allowlist"
    echo "# One CIDR per line. Clients outside these ranges are rejected by mtg."
    normalize_allowlist_cidrs
  } > "${ALLOWLIST_FILE}"
  chmod 0600 "${ALLOWLIST_FILE}"
}

write_config() {
  local allowlist_enabled allowlist_urls

  log "Writing ${CONFIG_FILE}"
  mkdir -p "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"
  confirm_overwrite

  allowlist_enabled="false"
  allowlist_urls=""
  if [[ "${ENABLE_ALLOWLIST}" -eq 1 ]]; then
    write_allowlist_file
    allowlist_enabled="true"
    allowlist_urls="  \"${ALLOWLIST_FILE}\","
  fi

  cat > "${CONFIG_FILE}" <<EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:3128"
concurrency = ${CONCURRENCY}
prefer-ip = "${PREFER_IP}"
auto-update = false
tolerate-time-skewness = "5s"
allow-fallback-on-unknown-dc = false

[domain-fronting]
port = 443

[network]
dns = "${DNS_RESOLVER}"

[network.timeout]
tcp = "5s"
http = "10s"
idle = "5m"
handshake = "10s"

[network.keep-alive]
disabled = false
idle = "15s"
interval = "15s"
count = 9

[defense.anti-replay]
enabled = true
max-size = "2mib"
error-rate = 0.001

[defense.blocklist]
enabled = true
download-concurrency = 2
urls = [
  "${BLOCKLIST_URL}",
]
update-each = "24h"

[defense.allowlist]
enabled = ${allowlist_enabled}
download-concurrency = 2
urls = [
${allowlist_urls}
]
update-each = "24h"

[stats.statsd]
enabled = false
address = "127.0.0.1:8888"
metric-prefix = "mtg"
tag-format = "datadog"

[stats.prometheus]
enabled = true
bind-to = "127.0.0.1:3129"
http-path = "/"
metric-prefix = "mtg"
EOF

  chmod 0600 "${CONFIG_FILE}"

cat > "${STATE_FILE}" <<EOF
DOMAIN='${DOMAIN}'
PORT='${PORT}'
ACTIVE_SECRET_LABEL='${ACTIVE_SECRET_LABEL}'
MTG_TAG='${MTG_TAG}'
PREFER_IP='${PREFER_IP}'
CONCURRENCY='${CONCURRENCY}'
DNS_RESOLVER='${DNS_RESOLVER}'
BLOCKLIST_URL='${BLOCKLIST_URL}'
ENABLE_ALLOWLIST='${ENABLE_ALLOWLIST}'
ALLOWLIST_CIDRS='${ALLOWLIST_CIDRS}'
ENABLE_NGINX_DISGUISE='${ENABLE_NGINX_DISGUISE}'
DISGUISE_SERVER_NAME='${DISGUISE_SERVER_NAME}'
DISGUISE_HTTP_PORT='${DISGUISE_HTTP_PORT}'
CONTAINER_NAME='${CONTAINER_NAME}'
CONFIG_FILE='${CONFIG_FILE}'
EOF
  chmod 0600 "${STATE_FILE}"
}

write_systemd_unit() {
  local docker_bin
  docker_bin="$(command -v docker)"
  log "Writing ${SYSTEMD_FILE}"

  cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=mtg MTProto proxy for Telegram (Docker)
Documentation=https://github.com/9seconds/mtg
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=5
TimeoutStartSec=0
LimitNOFILE=65536
ExecStartPre=-${docker_bin} rm -f ${CONTAINER_NAME}
ExecStartPre=${docker_bin} pull nineseconds/mtg:${MTG_TAG}
ExecStart=${docker_bin} run --rm --name ${CONTAINER_NAME} \\
  --publish ${PORT}:3128/tcp \\
  --volume ${CONFIG_FILE}:/config.toml:ro \\
  --ulimit nofile=65536:65536 \\
  --log-driver json-file \\
  --log-opt max-size=10m \\
  --log-opt max-file=5 \\
  nineseconds/mtg:${MTG_TAG} run /config.toml
ExecStop=${docker_bin} stop -t 10 ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${SYSTEMD_FILE}"
  systemctl daemon-reload
}

write_control_script() {
  log "Writing ${CONTROL_BIN}"

  cat > "${CONTROL_BIN}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="mtg.service"
STATE_FILE="/etc/mtg/install.env"
CONFIG_FILE="/etc/mtg/config.toml"
SECRETS_FILE="/etc/mtg/secrets.tsv"
ALLOWLIST_FILE="/etc/mtg/allowlist.netset"
CONTAINER_NAME="mtg-proxy"
PORT="443"
MTG_TAG="2.2.8"

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

usage() {
  cat <<USAGE
mtgctl - helper for clean mtg proxy installation

Usage:
  sudo mtgctl status
  sudo mtgctl logs [lines]
  sudo mtgctl follow
  sudo mtgctl doctor
  sudo mtgctl access
  sudo mtgctl qr
  sudo mtgctl speedtest
  sudo mtgctl bbr-nat
  sudo mtgctl restart
  sudo mtgctl stop
  sudo mtgctl start
  sudo mtgctl uninstall [--purge]
USAGE
}

need_root_for() {
  case "${1:-}" in
    logs|follow|status|doctor|access|qr|speedtest|bbr-nat|help|-h|--help) return 0 ;;
  esac
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this command with sudo" >&2
    exit 1
  fi
}

doctor() {
  docker run --rm -v "${CONFIG_FILE}:/config.toml:ro" "nineseconds/mtg:${MTG_TAG}" doctor /config.toml
}

active_secret() {
  local secret

  secret="$(awk -F'"' '/^secret[[:space:]]*=/{ print $2; exit }' "${CONFIG_FILE}" 2>/dev/null || true)"
  if [[ -n "${secret}" ]]; then
    printf '%s\n' "${secret}"
    return 0
  fi

  if [[ -f "${SECRETS_FILE}" ]]; then
    awk -F'\t' -v label="${ACTIVE_SECRET_LABEL:-default}" 'NF >= 3 && $1 == label { print $3; exit }' "${SECRETS_FILE}" 2>/dev/null || true
  fi
}

detect_public_server() {
  local public4 public6 local4

  if [[ -n "${SERVER_HOST:-}" ]]; then
    printf '%s\n' "${SERVER_HOST}"
    return 0
  fi

  if [[ -n "${PUBLIC_IP:-}" ]]; then
    printf '%s\n' "${PUBLIC_IP}"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    public4="$(curl -4 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ -n "${public4}" ]]; then
      printf '%s\n' "${public4}"
      return 0
    fi

    public4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ -n "${public4}" ]]; then
      printf '%s\n' "${public4}"
      return 0
    fi

    public6="$(curl -6 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ -n "${public6}" ]]; then
      printf '%s\n' "${public6}"
      return 0
    fi
  fi

  local4="$(hostname -I 2>/dev/null | awk '{ print $1; exit }' || true)"
  [[ -n "${local4}" ]] && printf '%s\n' "${local4}"
}

fallback_access_link() {
  local server secret

  secret="$(active_secret)"
  server="$(detect_public_server)"

  [[ -n "${server}" && -n "${PORT:-}" && -n "${secret}" ]] || return 1
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s\n' "${server}" "${PORT}" "${secret}"
}

access_info() {
  local output link
  output="$(
    docker exec "${CONTAINER_NAME}" /mtg access /config.toml 2>/dev/null \
      || docker run --rm -v "${CONFIG_FILE}:/config.toml:ro" "nineseconds/mtg:${MTG_TAG}" access /config.toml 2>/dev/null \
      || true
  )"
  [[ -n "${output}" ]] && printf '%s\n' "${output}"

  link="$(fallback_access_link || true)"
  if [[ -n "${link}" ]]; then
    echo
    echo "Public access link:"
    printf '%s\n' "${link}"
  else
    link="$(printf '%s\n' "${output}" | awk 'match($0, /(https:\/\/t\.me\/proxy[^[:space:]]+|tg:\/\/proxy[^[:space:]]+)/) { print substr($0, RSTART, RLENGTH); exit }')"
  fi

  [[ "${1:-}" == "--no-qr" ]] || print_qr "${link}"
}

print_qr() {
  local link
  link="$1"
  [[ -n "${link}" ]] || {
    echo "No proxy link found for QR generation" >&2
    return 1
  }

  echo
  echo "== QR code =="
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${link}"
  else
    echo "qrencode is not installed. Re-run installer or install package: qrencode"
  fi
}

bbr_nat_check() {
  local cc qdisc src4 src6 public4 public6

  echo "== BBR / TCP =="
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  printf 'tcp_congestion_control: %s\n' "${cc:-unknown}"
  printf 'default_qdisc:          %s\n' "${qdisc:-unknown}"
  if [[ "${cc}" == "bbr" ]]; then
    echo "BBR: enabled"
  else
    cat <<'TIP'
BBR: not enabled. Optional commands:
  echo "net.core.default_qdisc=fq" | sudo tee /etc/sysctl.d/99-clean-mtg-bbr.conf
  echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.d/99-clean-mtg-bbr.conf
  sudo sysctl --system
TIP
  fi

  echo
  echo "== NAT / public IP =="
  src4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  src6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  if command -v curl >/dev/null 2>&1; then
    public4="$(curl -4 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
    public6="$(curl -6 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
  else
    public4=""
    public6=""
  fi

  printf 'local IPv4 source: %s\n' "${src4:-unknown}"
  printf 'public IPv4:       %s\n' "${public4:-unknown}"
  if [[ -n "${src4}" && -n "${public4}" && "${src4}" != "${public4}" ]]; then
    echo "IPv4 NAT/cloud edge detected. Make sure mtg access links use the public IP."
  fi

  printf 'local IPv6 source: %s\n' "${src6:-unknown}"
  printf 'public IPv6:       %s\n' "${public6:-unknown}"

  echo
  echo "== Local listeners =="
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk -v port=":${PORT}" '$4 ~ port "$" { print }'
  else
    echo "ss is not installed"
  fi
}

tcp_check() {
  local host="$1"
  local start end elapsed
  start="$(date +%s%3N 2>/dev/null || date +%s)"
  if timeout 4 bash -c ":</dev/tcp/${host}/443" 2>/dev/null; then
    end="$(date +%s%3N 2>/dev/null || date +%s)"
    elapsed=$((end - start))
    printf 'telegram dc %-16s tcp/443 ok %sms\n' "${host}" "${elapsed}"
  else
    printf 'telegram dc %-16s tcp/443 failed\n' "${host}"
  fi
}

speedtest() {
  echo "== mtg doctor =="
  doctor || true
  echo
  echo "== Telegram TCP reachability =="
  tcp_check 149.154.175.50
  tcp_check 149.154.167.50
  tcp_check 149.154.175.100
  tcp_check 149.154.167.91
  tcp_check 91.108.56.130
  echo
  echo "== VPS HTTPS download baseline =="
  if command -v curl >/dev/null 2>&1; then
    curl -L -o /dev/null -sS \
      -w 'cloudflare 25MB: %{speed_download} bytes/s, total %{time_total}s\n' \
      'https://speed.cloudflare.com/__down?bytes=25000000' || true
  else
    echo "curl is not installed"
  fi
}

uninstall() {
  local purge=0
  if [[ "${1:-}" == "--purge" ]]; then
    purge=1
  fi

  systemctl disable --now "${SERVICE_NAME}" || true
  docker rm -f "${CONTAINER_NAME}" || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}" /usr/local/bin/mtgctl
  systemctl daemon-reload

  if [[ "${purge}" -eq 1 ]]; then
    rm -rf /etc/mtg
    echo "Removed service, container and /etc/mtg"
  else
    echo "Removed service and container. Config kept in /etc/mtg"
  fi
}

cmd="${1:-status}"
need_root_for "${cmd}"

case "${cmd}" in
  status)
    systemctl status "${SERVICE_NAME}" --no-pager || true
    docker ps --filter "name=${CONTAINER_NAME}" || true
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
    access_info
    ;;
  qr)
    access_info
    ;;
  bbr-nat)
    bbr_nat_check
    ;;
  speedtest)
    speedtest
    ;;
  restart)
    systemctl restart "${SERVICE_NAME}"
    ;;
  stop)
    systemctl stop "${SERVICE_NAME}"
    ;;
  start)
    systemctl start "${SERVICE_NAME}"
    ;;
  uninstall)
    uninstall "${2:-}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOF

  chmod 0755 "${CONTROL_BIN}"
}

bbr_nat_check() {
  local cc qdisc src4 src6 public4 public6

  echo "== BBR / TCP =="
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  printf 'tcp_congestion_control: %s\n' "${cc:-unknown}"
  printf 'default_qdisc:          %s\n' "${qdisc:-unknown}"
  if [[ "${cc}" == "bbr" ]]; then
    echo "BBR: enabled"
  else
    cat <<'TIP'
BBR: not enabled. Optional commands:
  echo "net.core.default_qdisc=fq" | sudo tee /etc/sysctl.d/99-clean-mtg-bbr.conf
  echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.d/99-clean-mtg-bbr.conf
  sudo sysctl --system
TIP
  fi

  echo
  echo "== NAT / public IP =="
  src4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  src6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true)"
  if cmd_exists curl; then
    public4="$(curl -4 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
    public6="$(curl -6 -fsS --max-time 5 https://ifconfig.co/ip 2>/dev/null | tr -d '\r\n ' || true)"
  else
    public4=""
    public6=""
  fi

  printf 'local IPv4 source: %s\n' "${src4:-unknown}"
  printf 'public IPv4:       %s\n' "${public4:-unknown}"
  if [[ -n "${src4}" && -n "${public4}" && "${src4}" != "${public4}" ]]; then
    echo "IPv4 NAT/cloud edge detected. Make sure mtg access links use the public IP."
  fi

  printf 'local IPv6 source: %s\n' "${src6:-unknown}"
  printf 'public IPv6:       %s\n' "${public6:-unknown}"

  echo
  echo "== Local listeners =="
  if cmd_exists ss; then
    ss -ltnp 2>/dev/null | awk -v port=":${PORT}" '$4 ~ port "$" { print }'
  else
    echo "ss is not installed"
  fi
}

run_bbr_nat_check() {
  [[ "${RUN_BBR_NAT_CHECK}" -eq 1 ]] || return
  log "Running optional BBR/NAT diagnostics"
  if [[ -x "${CONTROL_BIN}" ]]; then
    "${CONTROL_BIN}" bbr-nat || true
  else
    bbr_nat_check || true
  fi
}

install_nginx_package() {
  local pm
  pm="$(detect_pkg_manager)"

  if cmd_exists nginx; then
    return
  fi

  log "Installing Nginx (${pm})"
  case "${pm}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx
      ;;
    dnf)
      dnf install -y nginx
      ;;
    yum)
      yum install -y nginx
      ;;
    *)
      die "Cannot install Nginx automatically on this OS"
      ;;
  esac
}

open_disguise_firewall() {
  [[ "${CONFIGURE_FIREWALL}" -eq 1 ]] || return

  if cmd_exists ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${DISGUISE_HTTP_PORT}/tcp" comment "clean mtg nginx disguise"
    return
  fi

  if cmd_exists firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --add-port="${DISGUISE_HTTP_PORT}/tcp" --permanent
    firewall-cmd --reload
  fi
}

configure_nginx_disguise() {
  if [[ "${ENABLE_NGINX_DISGUISE}" -ne 1 ]]; then
    if [[ -f "${NGINX_SITE_FILE}" ]]; then
      log "Disabling Nginx disguise profile"
      rm -f "${NGINX_SITE_FILE}"
      if cmd_exists nginx; then
        if nginx -t; then
          systemctl reload nginx || true
        fi
      fi
    fi
    return
  fi

  install_nginx_package
  log "Writing Nginx disguise profile"
  mkdir -p "${NGINX_WEB_ROOT}"

  cat > "${NGINX_WEB_ROOT}/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>OK</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 3rem; color: #1f2937; }
    main { max-width: 42rem; }
  </style>
</head>
<body>
  <main>
    <h1>OK</h1>
    <p>This service is running.</p>
  </main>
</body>
</html>
EOF

  cat > "${NGINX_SITE_FILE}" <<EOF
server {
    listen ${DISGUISE_HTTP_PORT};
    listen [::]:${DISGUISE_HTTP_PORT};
    server_name ${DISGUISE_SERVER_NAME};

    root ${NGINX_WEB_ROOT};
    index index.html;

    add_header X-Robots-Tag "noindex, nofollow" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  open_disguise_firewall
}

configure_firewall() {
  [[ "${CONFIGURE_FIREWALL}" -eq 1 ]] || {
    warn "Firewall configuration skipped"
    return
  }

  log "Configuring firewall for TCP/${PORT}"

  if cmd_exists ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${PORT}/tcp" comment "mtg MTProto proxy"
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
      warn "Added a non-persistent iptables rule. Use ufw/firewalld/cloud firewall for persistence."
    fi
    return
  fi

  warn "No active ufw/firewalld detected. Open TCP/${PORT} in your VPS/cloud firewall if needed."
}

run_doctor() {
  [[ "${RUN_DOCTOR}" -eq 1 ]] || {
    warn "mtg doctor skipped"
    return
  }

  log "Running mtg doctor"
  if docker run --rm -v "${CONFIG_FILE}:/config.toml:ro" "nineseconds/mtg:${MTG_TAG}" doctor /config.toml; then
    log "mtg doctor finished successfully"
  else
    if [[ "${STRICT_DOCTOR}" -eq 1 ]]; then
      die "mtg doctor failed and --strict-doctor is enabled"
    fi
    warn "mtg doctor reported problems. Installation will continue; review output above."
  fi
}

start_service() {
  [[ "${START_SERVICE}" -eq 1 ]] || {
    warn "Service start skipped"
    return
  }

  log "Starting ${SERVICE_NAME}"
  systemctl enable --now "${SERVICE_NAME}"
  sleep 3
  systemctl is-active --quiet "${SERVICE_NAME}" || {
    journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
    die "${SERVICE_NAME} did not start"
  }
}

show_access() {
  [[ "${START_SERVICE}" -eq 1 ]] || return

  log "Access information"
  if ! "${CONTROL_BIN}" access; then
    warn "Could not generate access info yet. Try: sudo mtgctl access"
  fi
}

run_speedtest() {
  [[ "${RUN_SPEEDTEST}" -eq 1 && "${START_SERVICE}" -eq 1 ]] || return
  log "Running basic speed/connectivity test"
  "${CONTROL_BIN}" speedtest || warn "Speedtest finished with warnings"
}

summary() {
  cat <<EOF

Installed.

Files:
  Config:   ${CONFIG_FILE}
  Service:  ${SYSTEMD_FILE}
  Helper:   ${CONTROL_BIN}

Commands:
  sudo mtgctl status
  sudo mtgctl logs
  sudo mtgctl follow
  sudo mtgctl doctor
  sudo mtgctl access
  sudo mtgctl qr
  sudo mtgctl speedtest
  sudo mtgctl bbr-nat

If Telegram does not connect, also check your VPS provider firewall:
  open TCP/${PORT}
EOF
}

install_proxy() {
  install_packages
  ensure_docker
  generate_secret
  store_secret "${ACTIVE_SECRET_LABEL:-default}" "${DOMAIN}" "${SECRET}"
  write_config
  write_systemd_unit
  write_control_script
  configure_firewall
  configure_nginx_disguise
  run_doctor
  start_service
  show_access
  run_bbr_nat_check
  run_speedtest
  summary
}

main() {
  if [[ "$#" -eq 0 && -t 0 && -t 1 && -z "${DOMAIN}" ]]; then
    require_root
    menu_loop
  fi

  if [[ -z "${DOMAIN}" && -f "${STATE_FILE}" ]]; then
    load_state
  fi

  parse_args "$@"
  require_root
  validate_input
  install_proxy
}

main "$@"
