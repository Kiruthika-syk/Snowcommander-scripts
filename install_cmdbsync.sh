#!/bin/bash
# Standalone CMDB sync account provisioner for RHEL 9/10 templates.
# Extracted from install_security_tools.sh (2026snowcommander) - cmdbsync component only.
#
# Usage:
#   sudo ./install_cmdbsync.sh
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

CMDBSYNC_PASSWORD="${CMDBSYNC_PASSWORD:-}"
CMDBSYNC_UID="${CMDBSYNC_UID:-2800}"
CMDBSYNC_GID="${CMDBSYNC_GID:-1700}"

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

install_cmdbsync() {
  require_value CMDBSYNC_PASSWORD
  log "Configuring CMDB sync account"
  getent group cmdbsync >/dev/null || groupadd -g "$CMDBSYNC_GID" cmdbsync
  id cmdbsync >/dev/null 2>&1 || useradd -m -u "$CMDBSYNC_UID" \
    -g "$CMDBSYNC_GID" -c "CMDB account" -s /bin/bash cmdbsync
  printf 'cmdbsync:%s\n' "$CMDBSYNC_PASSWORD" | chpasswd

  local sudoers_tmp
  sudoers_tmp="$(mktemp)"
  cat >"$sudoers_tmp" <<'EOF'
cmdbsync ALL=(root) NOPASSWD:/bin/netstat,/bin/cat,/bin/ls,/usr/sbin/dmidecode,/usr/local/bin/dmidecode,/bin/find,/sbin/dmsetup,/sbin/fdisk,/sbin/multipath,/usr/sbin/lsof
cmdbsync ALL=(root) NOPASSWD:/usr/sbin/arp -n,/usr/bin/cat,/etc/oratab,/bin/cat,/etc/oratab,/usr/bin/grep,/usr/sbin/ifconfig -a,/sbin/route -n,/sbin/dmsetup table *,/usr/bin/dmsetup table *,/usr/sbin/dmsetup table *,/usr/bin/ps,/usr/sbin/lpfc/lputil,/usr/sbin/ndd,/usr/bin/adb,/usr/bin/cksum,/usr/bin/dd,/usr/bin/docker,/usr/bin/netstat,/usr/sbin/pvdisplay,/usr/sbin/lvdisplay,/usr/sbin/vgdisplay,/sbin/mii-tool,/usr/sbin/ethtool,/usr/bin/cksum,/sbin/vmcp,/usr/bin/ps,/usr/sbin/ifconfig,/usr/bin/cut,/usr/sbin/lshw,/usr/sbin/ss,/usr/bin/stat,/usr/bin/find
EOF
  chmod 440 "$sudoers_tmp"
  if ! visudo -cf "$sudoers_tmp" >/dev/null; then
    rm -f "$sudoers_tmp"
    fail "CMDB sudoers validation failed"
  fi
  install -o root -g root -m 440 "$sudoers_tmp" /etc/sudoers.d/cmdbsync
  rm -f "$sudoers_tmp"
  id cmdbsync
}

detect_platform
install_cmdbsync

log "Verification:"
id cmdbsync 2>/dev/null || true
visudo -cf /etc/sudoers.d/cmdbsync 2>/dev/null || true
log "CMDB sync account provisioning complete"
