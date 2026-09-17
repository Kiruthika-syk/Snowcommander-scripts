#!/bin/bash
# Standalone Tanium 7.8.4.1298 installer for RHEL 9/10 templates.
# Extracted from install_security_tools.sh (2026snowcommander) - tanium component only.
#
# Usage:
#   sudo ./install_tanium.sh
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

pick_tanium_rpm() {
  local major="$1" arch="$2"
  if [[ -n "${TANIUM_RPM:-}" ]]; then
    [[ -f "$TANIUM_RPM" ]] || return 1
    printf '%s\n' "$TANIUM_RPM"
    return 0
  fi

  local matches=()
  mapfile -t matches < <(
    compgen -G "${BASE_DIR}/tanium/TaniumClient-*.rhe${major}.${arch}.rpm" \
      | sort -V
  )
  ((${#matches[@]} > 0)) || return 1
  printf '%s\n' "${matches[-1]}"
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

install_tanium() {
  local tanium_dir="${BASE_DIR}/tanium"
  local init_path="${tanium_dir}/tanium-init.dat"
  [[ -f "$init_path" ]] || fail "Tanium init file missing: $init_path"

  local rpm_path
  rpm_path="$(pick_tanium_rpm "$OS_MAJOR" "$ARCH")" \
    || fail "No Tanium RPM found for RHEL $OS_MAJOR $ARCH in ${tanium_dir}"
  log "Using Tanium package: $rpm_path"

  local staged_version installed_version
  staged_version="$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$rpm_path")" \
    || fail "Cannot read Tanium RPM metadata: $rpm_path"
  installed_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}' TaniumClient 2>/dev/null || true)"
  if [[ "$installed_version" != "$staged_version" ]]; then
    install_local_rpm "$rpm_path"
  else
    log "Tanium $staged_version is already installed"
  fi
  install -d -m 755 /opt/Tanium/TaniumClient
  install -m 600 "$init_path" /opt/Tanium/TaniumClient/tanium-init.dat
  systemctl daemon-reload
  systemctl enable taniumclient.service 2>/dev/null || systemctl enable taniumclient
  systemctl restart taniumclient.service 2>/dev/null || systemctl restart taniumclient
  systemctl is-active --quiet taniumclient.service \
    || systemctl is-active --quiet taniumclient \
    || fail "Tanium service is not active"
}

detect_platform
install_tanium

log "Verification:"
rpm -q TaniumClient 2>/dev/null || true
systemctl is-active taniumclient.service 2>/dev/null || systemctl is-active taniumclient 2>/dev/null || true
log "Tanium install complete"
