#!/bin/bash
# Standalone Microsoft Sentinel / Azure Arc (azcmagent) installer for RHEL 9/10 templates.
# Extracted from install_security_tools.sh (2026snowcommander) - sentinel component only.
# Delegates the actual Arc onboarding to sentinel_core.sh (unchanged, in the same folder).
#
# Usage:
#   sudo ./install_sentinel.sh
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

install_sentinel() {
  local script="${BASE_DIR}/sentinel_core.sh"
  [[ -x "$script" ]] || fail "Sentinel installer missing: $script"
  local name hint mac show
  for name in AZCM_SP_CLIENT_ID AZCM_SP_SECRET AZCM_SUBSCRIPTION_ID \
    AZCM_RESOURCE_GROUP AZCM_TENANT_ID AZCM_LOCATION; do
    require_value "$name"
  done
  if [[ "$AZCM_SP_SECRET" == *REPLACE* ]] \
    || [[ "$AZCM_SP_SECRET" == *CHANGEME* ]] \
    || [[ ${#AZCM_SP_SECRET} -lt 8 ]]; then
    fail "AZCM_SP_SECRET appears invalid or placeholder"
  fi
  if [[ -z "${AZCM_RESOURCE_NAME:-}" ]]; then
    hint="$(hostname -s 2>/dev/null || hostname)"
    mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1 | tr -d ':' || true)"
    if [[ -n "$mac" && ${#mac} -ge 6 ]]; then
      export AZCM_RESOURCE_NAME="${hint}-${mac: -6}"
    else
      export AZCM_RESOURCE_NAME="${hint}-$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)"
    fi
    log "AZCM_RESOURCE_NAME not set; using ${AZCM_RESOURCE_NAME}"
  fi
  if command -v azcmagent >/dev/null 2>&1 && [[ "${SENTINEL_FORCE_RECONNECT:-0}" != "1" ]]; then
    show="$(azcmagent show 2>/dev/null || true)"
    if printf '%s' "$show" | grep -qiE 'Agent Status[^:]*:[[:space:]]*Connected' \
      && printf '%s' "$show" | grep -qF "$AZCM_SUBSCRIPTION_ID" \
      && printf '%s' "$show" | grep -qF "$AZCM_RESOURCE_GROUP"; then
      log "azcmagent already Connected to ${AZCM_RESOURCE_GROUP}; skipping re-onboarding"
      return 0
    fi
    if printf '%s' "$show" | grep -qiE 'Agent Status[^:]*:[[:space:]]*Disconnected'; then
      log "azcmagent is Disconnected; running reconnect"
    fi
  fi
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
  bash "$script"
  command -v azcmagent >/dev/null || fail "azcmagent not installed"
  azcmagent show 2>/dev/null | grep -qiE 'Agent Status[^:]*:[[:space:]]*Connected' \
    || fail "azcmagent installed but not Connected"
  azcmagent show 2>&1 | head -n 40 || true
}

detect_platform
install_sentinel

log "Verification:"
command -v azcmagent >/dev/null && azcmagent show 2>&1 | head -n 15 || true
log "Sentinel/Azure Arc install complete"
