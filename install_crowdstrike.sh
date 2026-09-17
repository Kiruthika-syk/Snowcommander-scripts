#!/bin/bash
# Standalone CrowdStrike Falcon sensor installer for RHEL 9/10 templates.
# Extracted from install_security_tools.sh (2026snowcommander) - crowdstrike component only.
#
# Usage:
#   sudo ./install_crowdstrike.sh
#
# Runs as tpx-admin: uses sudo -S with SSHPASS / PORTAL_SUDO_PASSWORD / .ssh_credentials.

set -uo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SECURITYTOOLS_ENV:-${BASE_DIR}/securitytools.env}"
LOG_FILE="${SECURITYTOOLS_LOG:-/var/log/securitytools-template-install.log}"

_load_sudo_password() {
  if [[ -n "${PORTAL_SUDO_PASSWORD:-}" ]]; then
    echo "$PORTAL_SUDO_PASSWORD"
    return 0
  fi
  if [[ -n "${SSHPASS:-}" ]]; then
    echo "$SSHPASS"
    return 0
  fi
  for creds in \
    /home/tpx-admin/crowdstrike/.ssh_credentials \
    /home/tpx-admin/may/ssh_fleet.env; do
    [[ -f "$creds" ]] || continue
    # shellcheck source=/dev/null
    source "$creds" 2>/dev/null || true
    if [[ -n "${SSHPASS:-}" ]]; then
      echo "$SSHPASS"
      return 0
    fi
    if [[ -n "${SSH_PASS:-}" ]]; then
      echo "$SSH_PASS"
      return 0
    fi
  done
  return 1
}

if [[ $EUID -ne 0 ]]; then
  pw="$(_load_sudo_password || true)"
  if [[ -z "$pw" ]]; then
    echo "ERROR: not root and no sudo password (set SSHPASS or PORTAL_SUDO_PASSWORD)" >&2
    exit 1
  fi
  if sudo -n true 2>/dev/null; then
    exec sudo -n bash "$0" "$@"
  fi
  printf '%s\n' "$pw" | sudo -S -p '' bash "$0" "$@"
  exit $?
fi

if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

FALCON_CID="${FALCON_CID:-}"
FALCON_PROVISIONING_TOKEN="${FALCON_PROVISIONING_TOKEN:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is missing in $CONFIG_FILE"
}

detect_platform() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release not found"
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_MAJOR="${VERSION_ID%%.*}"
  ARCH="$(uname -m)"
  [[ "$OS_ID" == "rhel" ]] || fail "This template supports RHEL only; detected ID=$OS_ID"
  [[ "$OS_MAJOR" == "9" || "$OS_MAJOR" == "10" ]] \
    || fail "This template supports RHEL 9/10 only; detected VERSION_ID=${VERSION_ID:-unknown}"
  [[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]] \
    || fail "Unsupported architecture: $ARCH"
  log "Platform validated: RHEL $OS_MAJOR $ARCH"
}

install_local_rpm() {
  local rpm_path="$1"
  [[ -f "$rpm_path" ]] || fail "RPM not found: $rpm_path"
  if command -v dnf >/dev/null 2>&1; then
    dnf localinstall -y --disablerepo='*' --nogpgcheck "$rpm_path" \
      || rpm -Uvh --replacepkgs "$rpm_path"
  else
    rpm -Uvh --replacepkgs "$rpm_path"
  fi
}

pick_falcon_rpm() {
  local major="$1" arch="$2"
  if [[ -n "${FALCON_RPM:-}" ]]; then
    [[ -f "$FALCON_RPM" ]] || return 1
    printf '%s\n' "$FALCON_RPM"
    return 0
  fi

  local matches=()
  mapfile -t matches < <(
    compgen -G "${BASE_DIR}/crowdstrike/falcon-sensor-*.el${major}.${arch}.rpm" \
      | sort -V
  )
  ((${#matches[@]} > 0)) || return 1
  printf '%s\n' "${matches[-1]}"
}

stop_falcon_cleanly() {
  log "Stopping any existing Falcon sensor processes"
  systemctl stop falcon-sensor.service 2>/dev/null || true
  sleep 2
  pkill -9 falcond 2>/dev/null || true
  pkill -9 falcon-sensor-bpf 2>/dev/null || true
  sleep 1
  systemctl reset-failed falcon-sensor.service 2>/dev/null || true
}

install_crowdstrike() {
  local rpm_path
  rpm_path="$(pick_falcon_rpm "$OS_MAJOR" "$ARCH")" || fail "No Falcon RPM found for RHEL $OS_MAJOR $ARCH"
  log "Using Falcon package: $rpm_path"
  require_value FALCON_CID
  stop_falcon_cleanly
  if ! rpm -q falcon-sensor >/dev/null 2>&1 && [[ ! -x /opt/CrowdStrike/falconctl ]]; then
    install_local_rpm "$rpm_path"
  else
    log "Upgrading/reinstalling Falcon sensor RPM"
    install_local_rpm "$rpm_path"
  fi
  local force=()
  # A CID carrying a 2-character checksum suffix (-F0, -FF, ...) needs -f so
  # falconctl will overwrite an already-provisioned CID on re-runs. Matching the
  # literal -F0 broke silently when the tenant CID changed suffix.
  [[ "$FALCON_CID" == *-[0-9A-Fa-f][0-9A-Fa-f] ]] && force=(-f)
  if [[ -n "$FALCON_PROVISIONING_TOKEN" ]]; then
    /opt/CrowdStrike/falconctl -s "${force[@]}" \
      --cid="$FALCON_CID" --provisioning-token="$FALCON_PROVISIONING_TOKEN"
  else
    /opt/CrowdStrike/falconctl -s "${force[@]}" --cid="$FALCON_CID"
  fi
  systemctl daemon-reload
  systemctl enable falcon-sensor.service
  systemctl restart falcon-sensor.service || systemctl start falcon-sensor.service
  sleep 3
  if ! systemctl is-active --quiet falcon-sensor.service; then
    log "Falcon not active after first start; retrying clean stop/start"
    stop_falcon_cleanly
    systemctl start falcon-sensor.service
    sleep 3
  fi
  systemctl is-active --quiet falcon-sensor.service || {
    systemctl status falcon-sensor.service --no-pager -l || true
    fail "Falcon service is not active"
  }
  /opt/CrowdStrike/falconctl -g --cid 2>/dev/null || true
  /opt/CrowdStrike/falconctl -g --aid 2>/dev/null || true
  log "Falcon service: $(systemctl is-active falcon-sensor.service)"
}

detect_platform
install_crowdstrike

log "Verification:"
rpm -q falcon-sensor 2>/dev/null || true
systemctl is-active falcon-sensor.service 2>/dev/null || true
[[ -x /opt/CrowdStrike/falconctl ]] && /opt/CrowdStrike/falconctl -g --aid 2>/dev/null || true
log "CrowdStrike install complete"
