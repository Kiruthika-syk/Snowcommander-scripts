#!/bin/bash
# Standalone rsyslog remote-forwarding installer for RHEL 9/10 templates.
# Extracted from install_security_tools.sh (2026snowcommander) - syslog component only.
#
# Usage:
#   sudo ./install_syslog.sh
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

SYSLOG_SERVER1="${SYSLOG_SERVER1:-10.132.118.100}"
SYSLOG_SERVER2="${SYSLOG_SERVER2:-10.50.118.100}"
SYSLOG_PORT="${SYSLOG_PORT:-514}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

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

install_syslog() {
  log "Installing and configuring rsyslog"
  rpm -q rsyslog >/dev/null 2>&1 || dnf install -y rsyslog
  install -d -m 755 /etc/rsyslog.d
  cat >/etc/rsyslog.d/60-securitytools-remote.conf <<EOF
# Managed by 2026snowcommander/install_syslog.sh
authpriv.* @${SYSLOG_SERVER1}:${SYSLOG_PORT}
*.* @${SYSLOG_SERVER2}:${SYSLOG_PORT}
EOF
  rsyslogd -N1 || fail "rsyslog config validation failed"
  systemctl enable rsyslog.service
  systemctl restart rsyslog.service
  systemctl is-active --quiet rsyslog.service || fail "rsyslog service is not active"
  logger -p authpriv.notice -t securitytools-template \
    "RHEL ${OS_MAJOR} security tools template syslog test from $(hostname)"
}

detect_platform
install_syslog

log "Verification:"
systemctl is-active rsyslog.service 2>/dev/null || true
grep -v '^#' /etc/rsyslog.d/60-securitytools-remote.conf 2>/dev/null || true
log "Syslog install complete"
