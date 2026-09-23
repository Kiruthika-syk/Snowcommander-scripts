#!/usr/bin/env bash
# ==============================================================================
# security.sh — main host-side security tooling orchestrator
#
# Runs ON the target Enterprise Linux host (RHEL / CentOS / Rocky / AlmaLinux /
# Oracle Linux, EL7-EL10, x86_64 or aarch64). Detects the platform, selects and
# validates the matching CrowdStrike and Tanium packages from the staged
# repositories, then installs and configures every requested component.
#
# Usage:
#   sudo ./security.sh all
#   sudo ./security.sh tanium crowdstrike cmdbsync sentinel syslog
#   sudo ./security.sh verify
#   sudo ./security.sh plan              # detect + select + validate, change nothing
#
# Exit codes:
#    0  every requested component succeeded (or was already compliant)
#    2  usage error
#    3  unsupported operating system
#    4  unsupported architecture
#    5  package selection or validation failure
#    6  insufficient privilege
#    7  required configuration missing
#   10  partial success (at least one component succeeded, at least one failed)
#   11  every requested component failed
#
# Idempotency: re-running is safe. Components compare desired state against
# actual state and report UNCHANGED rather than reinstalling or restarting a
# healthy production service.
#
# Configuration precedence: environment variables win over securitytools.env,
# so a container or CI runner can inject secrets without editing files on disk.
#
# Secret handling: secret *values* are redacted from stdout and the log file.
# Normal installation status is never hidden — every component reports a clear
# SUCCESS / UNCHANGED / FAILED line.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR" || {
  printf 'ERROR: cannot enter script directory: %s\n' "$BASE_DIR" >&2
  exit 1
}

CONFIG_FILE="${SECURITYTOOLS_ENV:-${BASE_DIR}/securitytools.env}"
LOG_FILE="${SECURITYTOOLS_LOG:-/var/log/securitytools-template-install.log}"

readonly VALID_COMPONENTS=(tanium crowdstrike cmdbsync sentinel syslog)

# ------------------------------------------------------------------------------
# Privilege escalation (behaviour preserved from the original installer).
# -E is added so environment-injected secrets survive the transition to root;
# without it, container-injected credentials would be silently dropped.
# ------------------------------------------------------------------------------
_load_sudo_password() {
  if [[ -n "${PORTAL_SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "$PORTAL_SUDO_PASSWORD"
    return 0
  fi
  if [[ -n "${SSHPASS:-}" ]]; then
    printf '%s\n' "$SSHPASS"
    return 0
  fi
  local creds
  for creds in \
    /home/tpx-admin/crowdstrike/.ssh_credentials \
    /home/tpx-admin/may/ssh_fleet.env; do
    [[ -r "$creds" ]] || continue
    # shellcheck source=/dev/null
    source "$creds" 2>/dev/null || true
    [[ -n "${SSHPASS:-}" ]] && { printf '%s\n' "$SSHPASS"; return 0; }
    [[ -n "${SSH_PASS:-}" ]] && { printf '%s\n' "$SSH_PASS"; return 0; }
  done
  return 1
}

if [[ $EUID -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    exec sudo -nE bash "$0" "$@"
  fi
  _pw="$(_load_sudo_password || true)"
  if [[ -z "${_pw:-}" ]]; then
    printf 'ERROR: root privileges are required. Run with sudo, or provide SSHPASS / PORTAL_SUDO_PASSWORD.\n' >&2
    exit 6
  fi
  printf '%s\n' "$_pw" | sudo -SE -p '' bash "$0" "$@"
  exit $?
fi

# ------------------------------------------------------------------------------
# Configuration loading — environment beats file, so injected secrets win.
# ------------------------------------------------------------------------------
readonly CONFIG_KEYS=(
  FALCON_CID FALCON_PROVISIONING_TOKEN FALCON_RPM FALCON_ALLOW_EL_FALLBACK
  TANIUM_RPM
  CMDBSYNC_PASSWORD CMDBSYNC_UID CMDBSYNC_GID CMDBSYNC_FORCE_PASSWORD
  SYSLOG_SERVER1 SYSLOG_SERVER2 SYSLOG_PORT
  AZCM_SP_CLIENT_ID AZCM_SP_SECRET AZCM_SUBSCRIPTION_ID AZCM_RESOURCE_GROUP
  AZCM_TENANT_ID AZCM_LOCATION AZCM_CLOUD AZCM_TAGS AZCM_CORRELATION_ID
  AZCM_DISCONNECT_BEFORE_CONNECT AZCM_RESOURCE_NAME SENTINEL_FORCE_RECONNECT
  RHSM_USERNAME RHSM_PASSWORD
)

# Values that must never reach stdout or the log file. The CID is deliberately
# absent: it is an identifier, not a credential, and is useful in logs.
readonly SECRET_KEYS=(
  FALCON_PROVISIONING_TOKEN
  CMDBSYNC_PASSWORD
  AZCM_SP_SECRET
  RHSM_PASSWORD
  PORTAL_SUDO_PASSWORD
  SSHPASS
)

declare -A _ENV_OVERRIDE=()
_snapshot_environment() {
  local key
  for key in "${CONFIG_KEYS[@]}"; do
    [[ -n "${!key:-}" ]] && _ENV_OVERRIDE["$key"]="${!key}"
  done
  return 0
}

_load_config_file() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
}

_reapply_environment() {
  local key
  for key in "${!_ENV_OVERRIDE[@]}"; do
    printf -v "$key" '%s' "${_ENV_OVERRIDE[$key]}"
    export "${key?}"
  done
  return 0
}

_snapshot_environment
_load_config_file
_reapply_environment

# Defaults applied after config load.
FALCON_CID="${FALCON_CID:-}"
FALCON_PROVISIONING_TOKEN="${FALCON_PROVISIONING_TOKEN:-}"
CMDBSYNC_PASSWORD="${CMDBSYNC_PASSWORD:-}"
CMDBSYNC_UID="${CMDBSYNC_UID:-2800}"
CMDBSYNC_GID="${CMDBSYNC_GID:-1700}"
SYSLOG_SERVER1="${SYSLOG_SERVER1:-10.132.118.100}"
SYSLOG_SERVER2="${SYSLOG_SERVER2:-10.50.118.100}"
SYSLOG_PORT="${SYSLOG_PORT:-514}"

# ------------------------------------------------------------------------------
# Logging with secret redaction.
#
# A sed filter sits between the script and both stdout and the log file, so any
# secret value is masked wherever it appears — including inside output produced
# by dnf, falconctl or azcmagent, which this script does not control.
# ------------------------------------------------------------------------------
_sed_escape() {
  printf '%s' "$1" | sed -e 's/[][\.*^$(){}?+|/\\]/\\&/g'
}

_start_redacted_logging() {
  # Fall back to a writable path rather than aborting when /var/log is not
  # writable (read-only filesystem, or a non-root dry run).
  if ! { mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE"; } 2>/dev/null; then
    local fallback="${TMPDIR:-/tmp}/securitytools-install.log"
    printf 'WARN: cannot write %s; logging to %s instead\n' "$LOG_FILE" "$fallback" >&2
    LOG_FILE="$fallback"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
  fi
  chmod 600 "$LOG_FILE" 2>/dev/null || true

  local -a exprs=()
  local key value escaped
  for key in "${SECRET_KEYS[@]}"; do
    value="${!key:-}"
    [[ -n "$value" ]] || continue
    # Very short values would mangle unrelated output; skip them.
    ((${#value} >= 6)) || continue
    escaped="$(_sed_escape "$value")"
    exprs+=(-e "s/${escaped}/***REDACTED***/g")
  done

  if ((${#exprs[@]} > 0)); then
    exec > >(sed -u "${exprs[@]}" | tee -a "$LOG_FILE") 2>&1
  else
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [component ...]

Components:
  all          install every component (default)
  tanium       Tanium client
  crowdstrike  CrowdStrike Falcon sensor
  cmdbsync     CMDB sync account and sudoers policy
  sentinel     Microsoft Sentinel / Azure Arc onboarding
  syslog       rsyslog remote forwarding

Modes:
  verify       report current state, change nothing
  plan         detect platform, select and validate packages, change nothing

Exit codes: 0 ok, 2 usage, 3 unsupported OS, 4 unsupported arch,
            5 package failure, 6 privilege, 7 config, 10 partial, 11 all failed
EOF
}

# Answer --help before touching the filesystem or setting up logging.
case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
esac

_start_redacted_logging

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------
SECTOOLS_IN_COMPONENT=0

_on_err() {
  local rc="$1" line="$2" cmd="$3"
  if [[ "$SECTOOLS_IN_COMPONENT" == "1" ]]; then
    log "  (component step failed at line ${line}, rc=${rc}: ${cmd})"
  else
    err "unexpected failure at line ${line} (rc=${rc}): ${cmd}"
  fi
}
trap '_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# shellcheck source=lib/pkg_select.sh
source "${BASE_DIR}/lib/pkg_select.sh"

# ------------------------------------------------------------------------------
# Component result tracking
# ------------------------------------------------------------------------------
declare -A COMPONENT_STATUS=()
declare -A COMPONENT_DETAIL=()
declare -a REQUESTED=()

SELECTED_FALCON=""
SELECTED_TANIUM=""

set_result() {
  local component="$1" status="$2" detail="${3:-}"
  # Keep details single-line so the machine-readable block stays parseable.
  detail="${detail//$'\n'/ }"
  COMPONENT_STATUS["$component"]="$status"
  COMPONENT_DETAIL["$component"]="$detail"
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    err "${name} is required but not set (checked environment and ${CONFIG_FILE})"
    return "$SECTOOLS_RC_CONFIG"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Safety helper: never blindly overwrite existing production configuration.
# ------------------------------------------------------------------------------
backup_file() {
  local target="$1"
  [[ -f "$target" ]] || return 0
  local stamp backup
  stamp="$(date '+%Y%m%d%H%M%S')"
  backup="${target}.sectools-bak.${stamp}"
  cp -a "$target" "$backup"
  log "  backed up existing ${target} -> ${backup}"
}

# install_if_changed <source temp file> <destination> <mode> [owner] [group]
# Writes only when content actually differs, backing up whatever was there.
# Returns 0 when it wrote, 1 when the destination was already correct.
install_if_changed() {
  local src="$1" dest="$2" mode="$3" owner="${4:-root}" group="${5:-root}"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    return 1
  fi
  backup_file "$dest"
  install -o "$owner" -g "$group" -m "$mode" "$src" "$dest"
  return 0
}

install_local_rpm() {
  local rpm_path="$1"
  [[ -f "$rpm_path" ]] || { err "RPM not found: $rpm_path"; return 1; }

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y --disablerepo='*' --nogpgcheck "$rpm_path" \
      || dnf localinstall -y --disablerepo='*' --nogpgcheck "$rpm_path" \
      || rpm -Uvh --replacepkgs "$rpm_path"
  elif command -v yum >/dev/null 2>&1; then
    # EL7 has no dnf.
    yum localinstall -y --disablerepo='*' --nogpgcheck "$rpm_path" \
      || rpm -Uvh --replacepkgs "$rpm_path"
  else
    rpm -Uvh --replacepkgs "$rpm_path"
  fi
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

# rpm -q prints "package NAME is not installed" to stdout on failure; never
# treat that text as a version string.
rpm_installed_version() {
  local name="$1"
  rpm -q "$name" >/dev/null 2>&1 || return 1
  rpm -q --qf '%{VERSION}-%{RELEASE}' "$name" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Package resolution — runs once, before any component executes, so an
# incompatible or corrupt package fails the run before it changes the host.
# ------------------------------------------------------------------------------
resolve_packages() {
  local need_falcon="$1" need_tanium="$2"

  if [[ "$need_falcon" == "1" ]]; then
    SELECTED_FALCON="$(sectools_select_falcon "${BASE_DIR}/crowdstrike" "$SECTOOLS_EL" "$SECTOOLS_ARCH")" \
      || return "$SECTOOLS_RC_PACKAGE"
    log "CrowdStrike package selected: $(basename "$SELECTED_FALCON")"
    sectools_validate_rpm "$SELECTED_FALCON" falcon-sensor "$SECTOOLS_ARCH" \
      || return "$SECTOOLS_RC_PACKAGE"
  fi

  if [[ "$need_tanium" == "1" ]]; then
    SELECTED_TANIUM="$(sectools_select_tanium "${BASE_DIR}/tanium" "$SECTOOLS_EL" "$SECTOOLS_ARCH")" \
      || return "$SECTOOLS_RC_PACKAGE"
    log "Tanium package selected: $(basename "$SELECTED_TANIUM")"
    sectools_validate_rpm "$SELECTED_TANIUM" TaniumClient "$SECTOOLS_ARCH" \
      || return "$SECTOOLS_RC_PACKAGE"
  fi

  return 0
}

# ==============================================================================
# Components
# ==============================================================================

# ------------------------------------------------------------------------------
# Tanium
# ------------------------------------------------------------------------------
install_tanium() {
  local init_src="${BASE_DIR}/tanium/tanium-init.dat"
  local init_dest=/opt/Tanium/TaniumClient/tanium-init.dat
  local rpm_path="$SELECTED_TANIUM"
  local changed=0

  [[ -f "$init_src" ]] || {
    err "Tanium init file missing: $init_src"
    set_result tanium FAILED "tanium-init.dat not staged"
    return 1
  }

  local staged installed
  staged="$(rpm -qp --nosignature --qf '%{VERSION}-%{RELEASE}' "$rpm_path" 2>/dev/null)" || staged=""
  installed="$(rpm_installed_version TaniumClient 2>/dev/null || true)"

  if [[ -n "$installed" && "$installed" == "$staged" ]]; then
    log "  TaniumClient ${installed} already installed"
  else
    if [[ -n "$installed" ]]; then
      log "  upgrading TaniumClient ${installed} -> ${staged}"
    else
      log "  installing TaniumClient ${staged}"
    fi
    install_local_rpm "$rpm_path" || { set_result tanium FAILED "rpm install failed"; return 1; }
    changed=1
  fi

  install -d -m 755 /opt/Tanium/TaniumClient
  if install_if_changed "$init_src" "$init_dest" 600; then
    log "  installed tanium-init.dat"
    changed=1
  else
    log "  tanium-init.dat already current"
  fi

  local unit=taniumclient.service
  systemctl list-unit-files 2>/dev/null | grep -q '^taniumclient' || unit=taniumclient

  systemctl daemon-reload
  systemctl enable "$unit" >/dev/null 2>&1 || systemctl enable taniumclient >/dev/null 2>&1 || true

  if [[ "$changed" == "1" ]]; then
    log "  restarting ${unit} (configuration changed)"
    systemctl restart "$unit" 2>/dev/null || systemctl restart taniumclient
  elif ! service_active "$unit" && ! service_active taniumclient; then
    log "  service inactive; starting ${unit}"
    systemctl start "$unit" 2>/dev/null || systemctl start taniumclient
    changed=1
  else
    log "  service already active; leaving it running"
  fi

  if ! service_active "$unit" && ! service_active taniumclient; then
    err "Tanium service is not active after configuration"
    set_result tanium FAILED "service inactive"
    return 1
  fi

  local final
  final="$(rpm_installed_version TaniumClient 2>/dev/null || echo unknown)"
  if [[ "$changed" == "1" ]]; then
    set_result tanium SUCCESS "TaniumClient ${final} active"
  else
    set_result tanium UNCHANGED "TaniumClient ${final} already compliant"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# CrowdStrike Falcon
# ------------------------------------------------------------------------------

# falconctl prints the CID without its checksum suffix and in lower case;
# normalise both sides to the bare 32 hex characters before comparing.
_normalize_cid() {
  printf '%s' "${1:-}" \
    | tr -d '"' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -oE '[0-9a-f]{32}' \
    | head -n1 || true
}

_falcon_current_cid() {
  [[ -x /opt/CrowdStrike/falconctl ]] || return 1
  /opt/CrowdStrike/falconctl -g --cid 2>/dev/null || true
}

stop_falcon_cleanly() {
  systemctl stop falcon-sensor.service 2>/dev/null || true
  sleep 2
  pkill -9 falcond 2>/dev/null || true
  pkill -9 falcon-sensor-bpf 2>/dev/null || true
  sleep 1
  systemctl reset-failed falcon-sensor.service 2>/dev/null || true
  return 0
}

install_crowdstrike() {
  local rpm_path="$SELECTED_FALCON"
  local changed=0

  require_value FALCON_CID || { set_result crowdstrike FAILED "FALCON_CID not set"; return 1; }

  local desired_cid
  desired_cid="$(_normalize_cid "$FALCON_CID")"
  if [[ ${#desired_cid} -ne 32 ]]; then
    err "FALCON_CID does not contain a valid 32-character CID: ${FALCON_CID}"
    set_result crowdstrike FAILED "malformed FALCON_CID"
    return 1
  fi
  # The CID is an identifier rather than a credential, so logging it is allowed.
  log "  target CID: ${desired_cid} (from ${FALCON_CID})"

  local staged installed
  staged="$(rpm -qp --nosignature --qf '%{VERSION}-%{RELEASE}' "$rpm_path" 2>/dev/null)" || staged=""
  installed="$(rpm_installed_version falcon-sensor 2>/dev/null || true)"

  local current_cid=""
  current_cid="$(_normalize_cid "$(_falcon_current_cid)")"

  # Already fully compliant: correct build, correct tenant, running.
  if [[ -n "$installed" && "$installed" == "$staged" \
    && "$current_cid" == "$desired_cid" ]] && service_active falcon-sensor.service; then
    log "  falcon-sensor ${installed} already installed, registered to ${desired_cid}, and active"
    set_result crowdstrike UNCHANGED "falcon-sensor ${installed} already compliant"
    return 0
  fi

  if [[ -n "$installed" && "$installed" != "$staged" ]]; then
    log "  upgrading falcon-sensor ${installed} -> ${staged}"
    stop_falcon_cleanly
    install_local_rpm "$rpm_path" || { set_result crowdstrike FAILED "rpm upgrade failed"; return 1; }
    changed=1
  elif [[ -z "$installed" ]]; then
    log "  installing falcon-sensor ${staged}"
    install_local_rpm "$rpm_path" || { set_result crowdstrike FAILED "rpm install failed"; return 1; }
    changed=1
  else
    log "  falcon-sensor ${installed} already installed"
  fi

  [[ -x /opt/CrowdStrike/falconctl ]] || {
    err "/opt/CrowdStrike/falconctl is missing after package installation"
    set_result crowdstrike FAILED "falconctl missing"
    return 1
  }

  if [[ "$current_cid" != "$desired_cid" ]]; then
    if [[ -n "$current_cid" ]]; then
      log "  re-registering sensor: ${current_cid} -> ${desired_cid}"
    else
      log "  registering sensor to ${desired_cid}"
    fi

    # A CID carrying a 2-character checksum suffix needs -f so falconctl will
    # overwrite an existing registration. Testing for the literal -F0 broke
    # silently when the tenant CID changed suffix.
    local force=()
    [[ "$FALCON_CID" == *-[0-9A-Fa-f][0-9A-Fa-f] ]] && force=(-f)

    # The provisioning token is a secret; it is redacted from stdout and the log.
    if [[ -n "$FALCON_PROVISIONING_TOKEN" ]]; then
      /opt/CrowdStrike/falconctl -s "${force[@]}" \
        --cid="$FALCON_CID" --provisioning-token="$FALCON_PROVISIONING_TOKEN" \
        || { set_result crowdstrike FAILED "falconctl registration failed"; return 1; }
    else
      /opt/CrowdStrike/falconctl -s "${force[@]}" --cid="$FALCON_CID" \
        || { set_result crowdstrike FAILED "falconctl registration failed"; return 1; }
    fi
    changed=1
  else
    log "  sensor already registered to ${desired_cid}"
  fi

  systemctl daemon-reload
  systemctl enable falcon-sensor.service >/dev/null 2>&1 || true

  if [[ "$changed" == "1" ]]; then
    log "  restarting falcon-sensor (configuration changed)"
    systemctl restart falcon-sensor.service 2>/dev/null \
      || systemctl start falcon-sensor.service
    sleep 3
  elif ! service_active falcon-sensor.service; then
    log "  service inactive; starting falcon-sensor"
    systemctl start falcon-sensor.service
    sleep 3
    changed=1
  fi

  if ! service_active falcon-sensor.service; then
    warn "falcon-sensor did not come up; retrying with a clean stop"
    stop_falcon_cleanly
    systemctl start falcon-sensor.service || true
    sleep 3
  fi

  if ! service_active falcon-sensor.service; then
    systemctl status falcon-sensor.service --no-pager -l 2>&1 | head -n 20 || true
    err "falcon-sensor service is not active"
    set_result crowdstrike FAILED "service inactive"
    return 1
  fi

  local aid
  aid="$(/opt/CrowdStrike/falconctl -g --aid 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -n1 || true)"
  if [[ -z "$aid" ]]; then
    warn "sensor is running but has not yet been assigned an AID (cloud registration may still be in progress)"
    set_result crowdstrike SUCCESS "falcon-sensor ${staged} active, AID pending"
    return 0
  fi

  log "  agent ID: ${aid}"
  if [[ "$changed" == "1" ]]; then
    set_result crowdstrike SUCCESS "falcon-sensor ${staged} active, AID ${aid}"
  else
    set_result crowdstrike UNCHANGED "falcon-sensor ${staged} already compliant, AID ${aid}"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# CMDB sync account
# ------------------------------------------------------------------------------
install_cmdbsync() {
  local changed=0 created=0

  if ! getent group cmdbsync >/dev/null; then
    log "  creating group cmdbsync (gid ${CMDBSYNC_GID})"
    groupadd -g "$CMDBSYNC_GID" cmdbsync
    changed=1
  else
    log "  group cmdbsync already present"
  fi

  if ! id cmdbsync >/dev/null 2>&1; then
    require_value CMDBSYNC_PASSWORD || { set_result cmdbsync FAILED "CMDBSYNC_PASSWORD not set"; return 1; }
    log "  creating user cmdbsync (uid ${CMDBSYNC_UID})"
    useradd -m -u "$CMDBSYNC_UID" -g "$CMDBSYNC_GID" \
      -c "CMDB account" -s /bin/bash cmdbsync
    created=1
    changed=1
  else
    log "  user cmdbsync already present"
  fi

  # Only touch the password on creation, or when explicitly forced. Silently
  # resetting an existing production account's password is not acceptable.
  if [[ "$created" == "1" || "${CMDBSYNC_FORCE_PASSWORD:-0}" == "1" ]]; then
    require_value CMDBSYNC_PASSWORD || { set_result cmdbsync FAILED "CMDBSYNC_PASSWORD not set"; return 1; }
    printf 'cmdbsync:%s\n' "$CMDBSYNC_PASSWORD" | chpasswd
    log "  password set for cmdbsync"
    changed=1
  else
    log "  leaving existing cmdbsync password untouched (set CMDBSYNC_FORCE_PASSWORD=1 to rotate)"
  fi

  local sudoers_tmp
  sudoers_tmp="$(mktemp)"
  cat >"$sudoers_tmp" <<'EOF'
cmdbsync ALL=(root) NOPASSWD:/bin/netstat,/bin/cat,/bin/ls,/usr/sbin/dmidecode,/usr/local/bin/dmidecode,/bin/find,/sbin/dmsetup,/sbin/fdisk,/sbin/multipath,/usr/sbin/lsof
cmdbsync ALL=(root) NOPASSWD:/usr/sbin/arp -n,/usr/bin/cat,/etc/oratab,/bin/cat,/etc/oratab,/usr/bin/grep,/usr/sbin/ifconfig -a,/sbin/route -n,/sbin/dmsetup table *,/usr/bin/dmsetup table *,/usr/sbin/dmsetup table *,/usr/bin/ps,/usr/sbin/lpfc/lputil,/usr/sbin/ndd,/usr/bin/adb,/usr/bin/cksum,/usr/bin/dd,/usr/bin/docker,/usr/bin/netstat,/usr/sbin/pvdisplay,/usr/sbin/lvdisplay,/usr/sbin/vgdisplay,/sbin/mii-tool,/usr/sbin/ethtool,/usr/bin/cksum,/sbin/vmcp,/usr/bin/ps,/usr/sbin/ifconfig,/usr/bin/cut,/usr/sbin/lshw,/usr/sbin/ss,/usr/bin/stat,/usr/bin/find
EOF
  chmod 440 "$sudoers_tmp"

  # Validate before it goes anywhere near /etc/sudoers.d.
  if ! visudo -cf "$sudoers_tmp" >/dev/null; then
    rm -f "$sudoers_tmp"
    err "generated cmdbsync sudoers policy failed validation; not installing it"
    set_result cmdbsync FAILED "sudoers validation failed"
    return 1
  fi

  if install_if_changed "$sudoers_tmp" /etc/sudoers.d/cmdbsync 440; then
    log "  installed /etc/sudoers.d/cmdbsync"
    changed=1
  else
    log "  /etc/sudoers.d/cmdbsync already current"
  fi
  rm -f "$sudoers_tmp"

  if ! visudo -cf /etc/sudoers.d/cmdbsync >/dev/null 2>&1; then
    err "installed cmdbsync sudoers policy does not validate"
    set_result cmdbsync FAILED "installed sudoers invalid"
    return 1
  fi

  if [[ "$changed" == "1" ]]; then
    set_result cmdbsync SUCCESS "account and sudoers policy configured"
  else
    set_result cmdbsync UNCHANGED "account and sudoers policy already compliant"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Sentinel / Azure Arc
# ------------------------------------------------------------------------------
install_sentinel() {
  local script="${BASE_DIR}/sentinel_core.sh"
  [[ -f "$script" ]] || {
    err "Sentinel installer missing: $script"
    set_result sentinel FAILED "sentinel_core.sh not staged"
    return 1
  }

  local name
  for name in AZCM_SP_CLIENT_ID AZCM_SP_SECRET AZCM_SUBSCRIPTION_ID \
    AZCM_RESOURCE_GROUP AZCM_TENANT_ID AZCM_LOCATION; do
    require_value "$name" || { set_result sentinel FAILED "${name} not set"; return 1; }
  done

  if [[ "$AZCM_SP_SECRET" == *REPLACE* ]] \
    || [[ "$AZCM_SP_SECRET" == *CHANGEME* ]] \
    || [[ ${#AZCM_SP_SECRET} -lt 8 ]]; then
    err "  AZCM_SP_SECRET appears invalid or placeholder"
    set_result sentinel FAILED "invalid AZCM_SP_SECRET"
    return 1
  fi

  if [[ -z "${AZCM_RESOURCE_NAME:-}" ]]; then
    local hint mac
    hint="$(hostname -s 2>/dev/null || hostname)"
    mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1 | tr -d ':' || true)"
    if [[ -n "$mac" && ${#mac} -ge 6 ]]; then
      export AZCM_RESOURCE_NAME="${hint}-${mac: -6}"
    else
      export AZCM_RESOURCE_NAME="${hint}-$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)"
    fi
    log "  AZCM_RESOURCE_NAME not set; using ${AZCM_RESOURCE_NAME}"
  fi

  # sentinel_core.sh disconnects before connecting, which is destructive for an
  # already-onboarded host. Skip entirely when the machine is connected to the
  # intended subscription and resource group.
  if command -v azcmagent >/dev/null 2>&1 && [[ "${SENTINEL_FORCE_RECONNECT:-0}" != "1" ]]; then
    local show
    show="$(azcmagent show 2>/dev/null || true)"
    if printf '%s' "$show" | grep -qiE 'Agent Status[^:]*:[[:space:]]*Connected' \
      && printf '%s' "$show" | grep -qF "$AZCM_SUBSCRIPTION_ID" \
      && printf '%s' "$show" | grep -qF "$AZCM_RESOURCE_GROUP"; then
      log "  azcmagent already Connected to ${AZCM_RESOURCE_GROUP}; skipping re-onboarding"
      log "  (set SENTINEL_FORCE_RECONNECT=1 to force a disconnect/reconnect cycle)"
      set_result sentinel UNCHANGED "already connected to ${AZCM_RESOURCE_GROUP}"
      return 0
    fi
    if printf '%s' "$show" | grep -qiE 'Agent Status[^:]*:[[:space:]]*Disconnected'; then
      log "  azcmagent is Disconnected; running reconnect (force-local disconnect + connect)"
    fi
  fi

  log "  onboarding host to Azure Arc in ${AZCM_RESOURCE_GROUP} (${AZCM_LOCATION}) as ${AZCM_RESOURCE_NAME}"

  # Secrets are passed through the environment, never on the command line, so
  # they cannot leak via the process table.
  AZURE_CLIENT_ID="$AZCM_SP_CLIENT_ID" \
  AZURE_CLIENT_SECRET="$AZCM_SP_SECRET" \
  AZURE_TENANT_ID="$AZCM_TENANT_ID" \
  AZURE_SUBSCRIPTION_ID="$AZCM_SUBSCRIPTION_ID" \
  AZURE_RESOURCE_GROUP="$AZCM_RESOURCE_GROUP" \
  AZURE_LOCATION="$AZCM_LOCATION" \
  AZURE_CLOUD="${AZCM_CLOUD:-AzureCloud}" \
  CORRELATION_ID="${AZCM_CORRELATION_ID:-$(cat /proc/sys/kernel/random/uuid)}" \
  AZCM_TAGS="${AZCM_TAGS:-Environment=Production}" \
  AZCM_DISCONNECT_BEFORE_CONNECT="${AZCM_DISCONNECT_BEFORE_CONNECT:-1}" \
  AZCM_RESOURCE_NAME="${AZCM_RESOURCE_NAME}" \
  PORTAL_SUDO_PASSWORD="${PORTAL_SUDO_PASSWORD:-${SSHPASS:-}}" \
    bash "$script" || {
    set_result sentinel FAILED "sentinel_core.sh returned non-zero"
    return 1
  }

  command -v azcmagent >/dev/null 2>&1 || {
    err "azcmagent is not present after onboarding"
    set_result sentinel FAILED "azcmagent not installed"
    return 1
  }

  if azcmagent show 2>/dev/null | grep -qi 'Agent Status.*: *Connected'; then
    set_result sentinel SUCCESS "connected to ${AZCM_RESOURCE_GROUP}"
  else
    err "azcmagent installed but not in a Connected state"
    set_result sentinel FAILED "agent not connected"
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# rsyslog forwarding
# ------------------------------------------------------------------------------
install_syslog() {
  local conf=/etc/rsyslog.d/60-securitytools-remote.conf
  local changed=0

  if ! rpm -q rsyslog >/dev/null 2>&1; then
    log "  installing rsyslog"
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y rsyslog || { set_result syslog FAILED "rsyslog install failed"; return 1; }
    elif command -v yum >/dev/null 2>&1; then
      yum install -y rsyslog || { set_result syslog FAILED "rsyslog install failed"; return 1; }
    else
      err "no dnf or yum available to install rsyslog"
      set_result syslog FAILED "no package manager"
      return 1
    fi
    changed=1
  else
    log "  rsyslog already installed"
  fi

  install -d -m 755 /etc/rsyslog.d

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Managed by snowcommander security.sh — changes will be overwritten.
authpriv.* @${SYSLOG_SERVER1}:${SYSLOG_PORT}
*.* @${SYSLOG_SERVER2}:${SYSLOG_PORT}
EOF

  if install_if_changed "$tmp" "$conf" 644; then
    log "  wrote ${conf} (forwarding to ${SYSLOG_SERVER1} and ${SYSLOG_SERVER2} on ${SYSLOG_PORT})"
    changed=1
  else
    log "  ${conf} already current"
  fi
  rm -f "$tmp"

  # Validate the whole rsyslog configuration before restarting the daemon.
  if ! rsyslogd -N1 >/dev/null 2>&1; then
    err "rsyslog configuration failed validation; restoring previous configuration"
    rsyslogd -N1 2>&1 | head -n 20 || true
    local newest
    newest="$(ls -1t "${conf}".sectools-bak.* 2>/dev/null | head -n1 || true)"
    if [[ -n "$newest" ]]; then
      cp -a "$newest" "$conf"
      log "  restored ${conf} from ${newest}"
    else
      rm -f "$conf"
      log "  removed ${conf} (no previous version to restore)"
    fi
    set_result syslog FAILED "rsyslog config validation failed"
    return 1
  fi

  systemctl enable rsyslog.service >/dev/null 2>&1 || true

  if [[ "$changed" == "1" ]]; then
    log "  restarting rsyslog (configuration changed)"
    systemctl restart rsyslog.service
  elif ! service_active rsyslog.service; then
    log "  service inactive; starting rsyslog"
    systemctl start rsyslog.service
    changed=1
  else
    log "  rsyslog already active; leaving it running"
  fi

  if ! service_active rsyslog.service; then
    err "rsyslog service is not active"
    set_result syslog FAILED "service inactive"
    return 1
  fi

  logger -p authpriv.notice -t securitytools-template \
    "security.sh syslog test from $(hostname) (el${SECTOOLS_EL} ${SECTOOLS_ARCH})" || true

  if [[ "$changed" == "1" ]]; then
    set_result syslog SUCCESS "forwarding to ${SYSLOG_SERVER1},${SYSLOG_SERVER2}:${SYSLOG_PORT}"
  else
    set_result syslog UNCHANGED "forwarding already configured"
  fi
  return 0
}

# ==============================================================================
# Verification
# ==============================================================================
verify_component() {
  local component="$1"

  case "$component" in
    tanium)
      local pkg svc
      pkg="$(rpm_installed_version TaniumClient 2>/dev/null || true)"
      if [[ -z "$pkg" ]]; then
        set_result tanium NOT_INSTALLED "TaniumClient package absent"
        return 0
      fi
      if service_active taniumclient.service || service_active taniumclient; then
        svc=active
        set_result tanium SUCCESS "TaniumClient ${pkg} active"
      else
        svc=inactive
        set_result tanium FAILED "TaniumClient ${pkg} installed but service ${svc}"
      fi
      ;;
    crowdstrike)
      local pkg aid cid
      pkg="$(rpm_installed_version falcon-sensor 2>/dev/null || true)"
      if [[ -z "$pkg" ]]; then
        if [[ -x /opt/CrowdStrike/falconctl ]]; then
          set_result crowdstrike FAILED "falconctl present but falcon-sensor package absent"
        else
          set_result crowdstrike NOT_INSTALLED "falcon-sensor package absent"
        fi
        return 0
      fi
      if ! service_active falcon-sensor.service; then
        set_result crowdstrike FAILED "falcon-sensor ${pkg} installed but service inactive"
        return 0
      fi
      cid="$(_normalize_cid "$(_falcon_current_cid)")"
      aid="$(/opt/CrowdStrike/falconctl -g --aid 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -n1 || true)"
      if [[ -z "$aid" ]]; then
        set_result crowdstrike PARTIAL "falcon-sensor ${pkg} active, CID ${cid:-unset}, no AID assigned"
      else
        set_result crowdstrike SUCCESS "falcon-sensor ${pkg} active, CID ${cid}, AID ${aid}"
      fi
      ;;
    cmdbsync)
      if ! id cmdbsync >/dev/null 2>&1; then
        set_result cmdbsync NOT_INSTALLED "user cmdbsync absent"
        return 0
      fi
      if [[ -f /etc/sudoers.d/cmdbsync ]] && visudo -cf /etc/sudoers.d/cmdbsync >/dev/null 2>&1; then
        set_result cmdbsync SUCCESS "user present, sudoers policy valid"
      else
        set_result cmdbsync PARTIAL "user present, sudoers policy missing or invalid"
      fi
      ;;
    sentinel)
      if ! command -v azcmagent >/dev/null 2>&1; then
        set_result sentinel NOT_INSTALLED "azcmagent absent"
        return 0
      fi
      if azcmagent show 2>/dev/null | grep -qi 'Agent Status.*: *Connected'; then
        set_result sentinel SUCCESS "azcmagent connected"
      else
        set_result sentinel PARTIAL "azcmagent installed but not connected"
      fi
      ;;
    syslog)
      if ! rpm -q rsyslog >/dev/null 2>&1; then
        set_result syslog NOT_INSTALLED "rsyslog package absent"
        return 0
      fi
      if ! service_active rsyslog.service; then
        set_result syslog FAILED "rsyslog installed but service inactive"
      elif [[ -f /etc/rsyslog.d/60-securitytools-remote.conf ]]; then
        set_result syslog SUCCESS "rsyslog active with remote forwarding configured"
      else
        set_result syslog PARTIAL "rsyslog active but remote forwarding config absent"
      fi
      ;;
  esac
  return 0
}

verify_all() {
  local component
  log "Verifying installed components"
  for component in "${VALID_COMPONENTS[@]}"; do
    verify_component "$component"
    log "  ${component}: ${COMPONENT_STATUS[$component]} — ${COMPONENT_DETAIL[$component]}"
  done
}

# ==============================================================================
# Reporting
# ==============================================================================
print_summary() {
  local component status detail
  local ok=0 failed=0

  echo
  echo "=============================================================================="
  echo " Security tooling summary — $(hostname -f 2>/dev/null || hostname)"
  echo " Platform: ${SECTOOLS_OS_NAME:-unknown} [el${SECTOOLS_EL:-?} ${SECTOOLS_ARCH:-?}]"
  echo "=============================================================================="
  printf ' %-14s %-14s %s\n' COMPONENT STATUS DETAIL
  printf ' %-14s %-14s %s\n' '--------------' '--------------' '----------------------------------------'

  for component in "${REQUESTED[@]}"; do
    status="${COMPONENT_STATUS[$component]:-NOT_RUN}"
    detail="${COMPONENT_DETAIL[$component]:-}"
    printf ' %-14s %-14s %s\n' "$component" "$status" "$detail"
    case "$status" in
      SUCCESS | UNCHANGED) ((ok++)) || true ;;
      *) ((failed++)) || true ;;
    esac
  done

  echo "=============================================================================="
  echo " ${ok} succeeded, ${failed} failed   |   log: ${LOG_FILE}"
  echo "=============================================================================="
  echo
}

# Machine-readable block consumed by the container orchestrator.
print_status_block() {
  local overall="$1" rc="$2" component

  echo "$SECTOOLS_STATUS_BEGIN"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "os_name=${SECTOOLS_OS_NAME:-unknown}"
  echo "os_id=${SECTOOLS_OS_ID:-unknown}"
  echo "os_version=${SECTOOLS_OS_VERSION:-unknown}"
  echo "el=${SECTOOLS_EL:-unknown}"
  echo "arch=${SECTOOLS_ARCH:-unknown}"
  [[ -n "$SELECTED_FALCON" ]] && echo "falcon_package=$(basename "$SELECTED_FALCON")"
  [[ -n "$SELECTED_TANIUM" ]] && echo "tanium_package=$(basename "$SELECTED_TANIUM")"
  for component in "${REQUESTED[@]}"; do
    echo "component=${component} status=${COMPONENT_STATUS[$component]:-NOT_RUN} detail=${COMPONENT_DETAIL[$component]:-}"
  done
  echo "overall=${overall}"
  echo "exit=${rc}"
  echo "$SECTOOLS_STATUS_END"
}

run_component() {
  local component="$1"
  echo
  log "----- ${component}: start -----"
  SECTOOLS_IN_COMPONENT=1
  if "install_${component}"; then
    SECTOOLS_IN_COMPONENT=0
    [[ -n "${COMPONENT_STATUS[$component]:-}" ]] \
      || set_result "$component" SUCCESS "completed without a reported detail"
  else
    SECTOOLS_IN_COMPONENT=0
    [[ -n "${COMPONENT_STATUS[$component]:-}" ]] \
      || set_result "$component" FAILED "unspecified failure"
  fi
  log "----- ${component}: ${COMPONENT_STATUS[$component]} -----"
  return 0
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  local -a args=("$@")
  ((${#args[@]} > 0)) || args=(all)

  log "security.sh starting — $(hostname -f 2>/dev/null || hostname)"
  log "Configuration file: ${CONFIG_FILE}$([[ -r "$CONFIG_FILE" ]] || printf ' (absent; using environment only)')"

  # Platform detection gates everything.
  sectools_detect_platform || exit $?

  # verify / plan short-circuit before any change is made.
  if [[ "${args[0]}" == "verify" ]]; then
    REQUESTED=("${VALID_COMPONENTS[@]}")
    verify_all
    print_summary
    local bad=0 c
    for c in "${REQUESTED[@]}"; do
      case "${COMPONENT_STATUS[$c]:-NOT_RUN}" in
        SUCCESS | UNCHANGED | NOT_INSTALLED) ;;
        *) ((bad++)) || true ;;
      esac
    done
    if ((bad == 0)); then
      print_status_block SUCCESS 0
      exit 0
    fi
    print_status_block PARTIAL "$SECTOOLS_RC_PARTIAL"
    exit "$SECTOOLS_RC_PARTIAL"
  fi

  if [[ "${args[0]}" == "plan" ]]; then
    REQUESTED=()
    resolve_packages 1 1 || exit $?
    log "plan complete — no changes were made"
    print_status_block SUCCESS 0
    exit 0
  fi

  # Expand and validate the requested component list.
  if [[ "${args[0]}" == "all" ]]; then
    REQUESTED=("${VALID_COMPONENTS[@]}")
  else
    local requested component valid
    for requested in "${args[@]}"; do
      valid=0
      for component in "${VALID_COMPONENTS[@]}"; do
        [[ "$requested" == "$component" ]] && valid=1 && break
      done
      if ((valid == 0)); then
        err "unknown component: ${requested}"
        usage
        exit "$SECTOOLS_RC_USAGE"
      fi
      REQUESTED+=("$requested")
    done
  fi

  log "Requested components: ${REQUESTED[*]}"

  # Resolve and validate packages up front so an incompatible or corrupt
  # package aborts the run before the host is modified.
  local need_falcon=0 need_tanium=0 c
  for c in "${REQUESTED[@]}"; do
    [[ "$c" == "crowdstrike" ]] && need_falcon=1
    [[ "$c" == "tanium" ]] && need_tanium=1
  done
  if ((need_falcon || need_tanium)); then
    resolve_packages "$need_falcon" "$need_tanium" || exit $?
  fi

  for c in "${REQUESTED[@]}"; do
    run_component "$c"
  done

  print_summary

  local ok=0 failed=0
  for c in "${REQUESTED[@]}"; do
    case "${COMPONENT_STATUS[$c]:-NOT_RUN}" in
      SUCCESS | UNCHANGED) ((ok++)) || true ;;
      *) ((failed++)) || true ;;
    esac
  done

  if ((failed == 0)); then
    print_status_block SUCCESS 0
    exit 0
  fi
  if ((ok > 0)); then
    log "Partial success: ${ok} succeeded, ${failed} failed"
    print_status_block PARTIAL "$SECTOOLS_RC_PARTIAL"
    exit "$SECTOOLS_RC_PARTIAL"
  fi
  log "All requested components failed"
  print_status_block FAILED "$SECTOOLS_RC_ALL_FAILED"
  exit "$SECTOOLS_RC_ALL_FAILED"
}

main "$@"
