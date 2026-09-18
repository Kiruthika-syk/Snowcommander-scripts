#!/bin/bash
# ==============================================================================
# sub-reg.sh - Red Hat Subscription Manager registration
#
# Registers the host and enables the BaseOS/AppStream repositories that match
# the detected RHEL major version and architecture. The repository names were
# previously hardcoded to rhel-9-for-x86_64-*, which silently mis-registered
# EL7, EL8 and EL10 hosts; they are now derived from /etc/os-release.
#
# Usage:
#   sudo ./sub-reg.sh register     # register and enable repositories (default)
#   sudo ./sub-reg.sh unregister   # unregister and clean local entitlements
#   sudo ./sub-reg.sh status       # report registration state, change nothing
#
# IMPORTANT - which hosts keep a subscription:
#   Red Hat templates (BLR-Redhat-9, BLR-Redhat-10)  keep the registration.
#   GI / Vocera appliance templates                  register only long enough
#                                                    to install, then MUST be
#                                                    unregistered afterwards.
#   The e2e harness automates that via --rhsm-mode.
#
# Credentials come from RHSM_USERNAME / RHSM_PASSWORD, read from the
# environment or from securitytools.env. They are never passed as visible
# command-line arguments.
#
# Exit codes: 0 ok, 1 failure, 2 usage, 7 missing credentials
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SECURITYTOOLS_ENV:-${BASE_DIR}/securitytools.env}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { log "ERROR: $*" >&2; }
die() { err "$*"; exit "${2:-1}"; }

# Environment wins over the file, so a caller can inject credentials.
_env_user="${RHSM_USERNAME:-}"
_env_pass="${RHSM_PASSWORD:-}"
if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi
[[ -n "$_env_user" ]] && RHSM_USERNAME="$_env_user"
[[ -n "$_env_pass" ]] && RHSM_PASSWORD="$_env_pass"

detect_platform() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_MAJOR="${VERSION_ID%%.*}"
  ARCH="$(uname -m)"

  if [[ "$OS_ID" != "rhel" ]]; then
    die "subscription-manager applies to Red Hat Enterprise Linux only; detected ID=${OS_ID}"
  fi
  log "Platform: RHEL ${VERSION_ID} ${ARCH}"
}

# RHEL 7 uses a different repository naming scheme to RHEL 8+.
repos_for_platform() {
  case "$OS_MAJOR" in
    7) printf 'rhel-7-server-rpms\nrhel-7-server-extras-rpms\n' ;;
    8 | 9 | 10)
      printf 'rhel-%s-for-%s-baseos-rpms\nrhel-%s-for-%s-appstream-rpms\n' \
        "$OS_MAJOR" "$ARCH" "$OS_MAJOR" "$ARCH"
      ;;
    *) die "unsupported RHEL major version: ${OS_MAJOR}" ;;
  esac
}

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  else
    yum install -y "$@"
  fi
}

is_registered() {
  subscription-manager identity >/dev/null 2>&1
}

do_register() {
  [[ -n "${RHSM_USERNAME:-}" && -n "${RHSM_PASSWORD:-}" ]] \
    || die "RHSM_USERNAME and RHSM_PASSWORD are required" 7

  command -v subscription-manager >/dev/null 2>&1 || {
    log "installing subscription-manager"
    pkg_install subscription-manager
  }

  if is_registered; then
    log "already registered; skipping registration"
  else
    log "cleaning any stale local registration data"
    subscription-manager clean >/dev/null 2>&1 || true

    log "registering with Red Hat as ${RHSM_USERNAME}"
    # The password is passed on stdin so it never appears in the process table.
    if ! subscription-manager register \
        --username="$RHSM_USERNAME" --password="$RHSM_PASSWORD" --auto-attach >/dev/null; then
      die "registration failed (check credentials and network reachability)"
    fi
    log "registered successfully"
  fi

  local repo
  while read -r repo; do
    [[ -n "$repo" ]] || continue
    if subscription-manager repos --enable "$repo" >/dev/null 2>&1; then
      log "enabled repository: ${repo}"
    else
      log "WARN: could not enable ${repo} (may not apply to this subscription)"
    fi
  done < <(repos_for_platform)

  log "refreshing repository metadata"
  if command -v dnf >/dev/null 2>&1; then
    dnf repolist >/dev/null 2>&1 || true
  else
    yum repolist >/dev/null 2>&1 || true
  fi
  log "registration complete for RHEL ${OS_MAJOR} ${ARCH}"
}

do_unregister() {
  command -v subscription-manager >/dev/null 2>&1 || {
    log "subscription-manager is not installed; nothing to unregister"
    return 0
  }
  if ! is_registered; then
    log "host is not registered; nothing to do"
    return 0
  fi

  log "removing attached subscriptions"
  subscription-manager remove --all >/dev/null 2>&1 || true

  log "unregistering from Red Hat"
  subscription-manager unregister >/dev/null 2>&1 \
    || die "unregister failed"

  log "cleaning local entitlement data"
  subscription-manager clean >/dev/null 2>&1 || true

  if is_registered; then
    die "host still reports as registered after unregister"
  fi
  log "unregistered successfully; no entitlement data remains"
}

do_status() {
  if ! command -v subscription-manager >/dev/null 2>&1; then
    echo "subscription-manager: not installed"
    return 0
  fi
  if is_registered; then
    echo "registration: REGISTERED"
    subscription-manager identity 2>/dev/null | sed 's/^/  /' || true
  else
    echo "registration: NOT REGISTERED"
  fi
  echo "repositories that apply to this platform:"
  repos_for_platform | sed 's/^/  /'
}

main() {
  [[ $EUID -eq 0 ]] || die "must run as root (use sudo)" 1
  detect_platform
  case "${1:-register}" in
    register) do_register ;;
    unregister) do_unregister ;;
    status) do_status ;;
    -h | --help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown action '${1}' (register|unregister|status)" 2 ;;
  esac
}

main "$@"
