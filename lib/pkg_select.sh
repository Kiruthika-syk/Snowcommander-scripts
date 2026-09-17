#!/usr/bin/env bash
# ==============================================================================
# pkg_select.sh — OS/architecture detection, package selection and validation.
#
# Sourced by security.sh (on the target host) and by the container orchestrator
# (for pre-flight validation). Also runnable standalone:
#
#   ./lib/pkg_select.sh report              # detect this host, show selection
#   ./lib/pkg_select.sh matrix              # full staged-package inventory
#   ./lib/pkg_select.sh select <el> <arch>  # dry-run selection for a target
#
# Selection is version-agnostic: packages are matched by glob and the highest
# version wins (sort -V). Staging a newer sensor build requires no code change.
#
# Selection is validated against RPM *metadata*, not filenames, because the
# staged Tanium packages carry glibc-based release strings (glibc2.17 /
# glibc2.26) rather than per-RHEL-version releases. The "rheN" in a Tanium
# filename is cosmetic and the x86_64 payloads for rhe7/8/9/10 are identical.
# ==============================================================================

[[ -n "${_SECTOOLS_PKG_SELECT_LOADED:-}" ]] && return 0
_SECTOOLS_PKG_SELECT_LOADED=1

# ------------------------------------------------------------------------------
# Exit codes — shared contract with security.sh and the orchestrator
# ------------------------------------------------------------------------------
readonly SECTOOLS_RC_OK=0
readonly SECTOOLS_RC_USAGE=2
readonly SECTOOLS_RC_UNSUPPORTED_OS=3
readonly SECTOOLS_RC_UNSUPPORTED_ARCH=4
readonly SECTOOLS_RC_PACKAGE=5
readonly SECTOOLS_RC_PRIVILEGE=6
readonly SECTOOLS_RC_CONFIG=7
readonly SECTOOLS_RC_PARTIAL=10
readonly SECTOOLS_RC_ALL_FAILED=11

# Markers the orchestrator greps for in remote output.
readonly SECTOOLS_STATUS_BEGIN='###SECTOOLS_STATUS_BEGIN'
readonly SECTOOLS_STATUS_END='###SECTOOLS_STATUS_END'

# Populated by sectools_detect_platform.
SECTOOLS_OS_ID=""
SECTOOLS_OS_NAME=""
SECTOOLS_OS_VERSION=""
SECTOOLS_OS_MAJOR=""
SECTOOLS_OS_FAMILY=""
SECTOOLS_EL=""
SECTOOLS_ARCH=""

# Fallback loggers so this file works standalone and when sourced.
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { log "WARN: $*"; }
fi

# ------------------------------------------------------------------------------
# sectools_normalize_arch <uname -m value>  ->  x86_64 | aarch64
# ------------------------------------------------------------------------------
sectools_normalize_arch() {
  case "${1:-}" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# sectools_os_to_el <os_id> <major> [id_like]  ->  elN tag
#
# Debian/Ubuntu and Fedora deliberately return non-zero: no .deb packages are
# staged and no Fedora build exists, so substituting an EL RPM would be worse
# than failing loudly.
# ------------------------------------------------------------------------------
# Emits "<family> <el>" on success and "<family>" on failure, because callers
# invoke this in a command substitution: a subshell cannot export the family
# back through a global.
sectools_os_to_el() {
  local os_id="${1:-}" major="${2:-}" id_like="${3:-}"
  local family=""

  case "$os_id" in
    rhel | redhat | redhatenterpriseserver) family="rhel" ;;
    centos) family="centos" ;;
    rocky) family="rocky" ;;
    almalinux | alma) family="almalinux" ;;
    ol | oracle | oraclelinux) family="oraclelinux" ;;
    scientific | springdalelinux | virtuozzo | circle) family="el-derivative" ;;
    ubuntu | debian | linuxmint | pop)
      printf 'debian\n'
      return 1
      ;;
    fedora)
      printf 'fedora\n'
      return 1
      ;;
    *)
      if [[ " $id_like " == *" rhel "* ]] || [[ " $id_like " == *" centos "* ]]; then
        family="el-like"
      else
        printf 'unknown\n'
        return 1
      fi
      ;;
  esac

  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$family"
    return 1
  fi
  printf '%s %s\n' "$family" "$major"
}

# ------------------------------------------------------------------------------
# sectools_detect_platform — populates SECTOOLS_* globals from os-release+uname
# ------------------------------------------------------------------------------
sectools_detect_platform() {
  local os_release="${SECTOOLS_OS_RELEASE_FILE:-/etc/os-release}"

  if [[ ! -r "$os_release" ]]; then
    log "ERROR: cannot read ${os_release}; unable to identify the operating system"
    return "$SECTOOLS_RC_UNSUPPORTED_OS"
  fi

  local id="" version_id="" pretty_name="" id_like=""
  local line key value
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$key" in
      ID) id="$value" ;;
      VERSION_ID) version_id="$value" ;;
      PRETTY_NAME) pretty_name="$value" ;;
      ID_LIKE) id_like="$value" ;;
    esac
  done <"$os_release"

  SECTOOLS_OS_ID="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  SECTOOLS_OS_VERSION="$version_id"
  SECTOOLS_OS_MAJOR="${version_id%%.*}"
  SECTOOLS_OS_NAME="${pretty_name:-${SECTOOLS_OS_ID} ${version_id}}"

  local mapping="" mapping_rc=0
  mapping="$(sectools_os_to_el "$SECTOOLS_OS_ID" "$SECTOOLS_OS_MAJOR" "$id_like")" || mapping_rc=$?
  SECTOOLS_OS_FAMILY="${mapping%% *}"

  local el=""
  [[ "$mapping" == *" "* ]] && el="${mapping##* }"

  if ((mapping_rc != 0)) || [[ -z "$el" ]]; then
    log "ERROR: unsupported operating system: ${SECTOOLS_OS_NAME} (ID=${SECTOOLS_OS_ID}, VERSION_ID=${SECTOOLS_OS_VERSION})"
    case "$SECTOOLS_OS_FAMILY" in
      debian) log "ERROR: this repository stages Enterprise Linux .rpm packages only; no .deb package is present for Debian/Ubuntu targets" ;;
      fedora) log "ERROR: Fedora is not an Enterprise Linux release; no matching elN package is staged" ;;
      *) log "ERROR: expected an Enterprise Linux derivative (RHEL, CentOS, Rocky, AlmaLinux, Oracle Linux)" ;;
    esac
    return "$SECTOOLS_RC_UNSUPPORTED_OS"
  fi
  SECTOOLS_EL="$el"

  local raw_arch
  raw_arch="$(uname -m)"
  if ! SECTOOLS_ARCH="$(sectools_normalize_arch "$raw_arch")"; then
    log "ERROR: unsupported architecture: ${raw_arch} (staged packages cover x86_64 and aarch64 only)"
    return "$SECTOOLS_RC_UNSUPPORTED_ARCH"
  fi

  log "Platform detected: ${SECTOOLS_OS_NAME} [family=${SECTOOLS_OS_FAMILY} el=${SECTOOLS_EL} arch=${SECTOOLS_ARCH}]"
  return 0
}

# ------------------------------------------------------------------------------
# sectools_rpm_field <path> <tag> — read one header tag.
# --nosignature so a missing vendor GPG key is not mistaken for corruption.
# ------------------------------------------------------------------------------
sectools_rpm_field() {
  command -v rpm >/dev/null 2>&1 || return 1
  rpm -qp --nosignature --qf "%{${2}}" "$1" 2>/dev/null
}

# ------------------------------------------------------------------------------
# sectools_list_available <dir> <glob> — show what IS staged, so mismatches are
# actionable rather than just "not found".
# ------------------------------------------------------------------------------
sectools_list_available() {
  local dir="$1" pattern="$2" f
  local -a found=()
  local saved
  saved="$(shopt -p nullglob || true)"
  shopt -s nullglob
  # shellcheck disable=SC2206
  found=(${dir}/${pattern})
  eval "$saved" 2>/dev/null || true

  if ((${#found[@]} == 0)); then
    log "       (nothing matching ${pattern} in ${dir})"
    return 0
  fi
  log "       staged in ${dir}:"
  for f in "${found[@]}"; do
    log "         - $(basename "$f")"
  done
}

# ------------------------------------------------------------------------------
# sectools_validate_rpm <path> <expected name> <host arch>
#
# Gates every candidate before install:
#   1. present, readable, non-empty
#   2. header parseable          (catches non-RPM / badly truncated files)
#   3. package name as expected
#   4. package arch installable on this host
#   5. payload digests verify    (catches truncated or partial downloads)
#
# Set SECTOOLS_SKIP_DIGEST=1 to skip step 5 (faster, less safe).
# ------------------------------------------------------------------------------
sectools_validate_rpm() {
  local path="$1" expected_name="$2" host_arch="$3"

  [[ -f "$path" ]] || { log "ERROR: package not found: $path"; return "$SECTOOLS_RC_PACKAGE"; }
  [[ -r "$path" ]] || { log "ERROR: package not readable: $path"; return "$SECTOOLS_RC_PACKAGE"; }
  [[ -s "$path" ]] || { log "ERROR: package is empty: $path"; return "$SECTOOLS_RC_PACKAGE"; }

  if ! command -v rpm >/dev/null 2>&1; then
    warn "rpm unavailable; skipping metadata and digest validation of $(basename "$path")"
    return 0
  fi

  local pkg_name pkg_arch pkg_evr
  pkg_name="$(sectools_rpm_field "$path" NAME || true)"
  pkg_arch="$(sectools_rpm_field "$path" ARCH || true)"
  pkg_evr="$(rpm -qp --nosignature --qf '%{VERSION}-%{RELEASE}' "$path" 2>/dev/null || true)"

  if [[ -z "$pkg_name" ]]; then
    log "ERROR: cannot read RPM header — not a valid package, or badly truncated: $path"
    return "$SECTOOLS_RC_PACKAGE"
  fi

  if [[ "$pkg_name" != "$expected_name" ]]; then
    log "ERROR: package name mismatch in $(basename "$path"): expected '${expected_name}', header says '${pkg_name}'"
    return "$SECTOOLS_RC_PACKAGE"
  fi

  case "$pkg_arch" in
    noarch | "$host_arch") : ;;
    *)
      log "ERROR: architecture mismatch in $(basename "$path"): package is '${pkg_arch}', host is '${host_arch}'"
      return "$SECTOOLS_RC_PACKAGE"
      ;;
  esac

  if [[ "${SECTOOLS_SKIP_DIGEST:-0}" != "1" ]]; then
    local digest_out digest_rc=0
    digest_out="$(rpm -K --nosignature "$path" 2>&1)" || digest_rc=$?
    if [[ $digest_rc -ne 0 ]] || printf '%s' "$digest_out" | grep -qi 'NOT OK'; then
      local on_disk declared
      on_disk="$(stat -c '%s' "$path" 2>/dev/null || echo unknown)"
      declared="$(sectools_rpm_field "$path" SIZE || echo unknown)"
      log "ERROR: payload digest verification FAILED for $(basename "$path")"
      log "ERROR:   rpm -K reported: ${digest_out}"
      log "ERROR:   bytes on disk: ${on_disk}; payload size declared by header: ${declared}"
      log "ERROR:   package is corrupt or incompletely downloaded — re-stage from the vendor before deploying"
      return "$SECTOOLS_RC_PACKAGE"
    fi
  fi

  log "Validated $(basename "$path"): ${pkg_name} ${pkg_evr} ${pkg_arch}"
  return 0
}

# ------------------------------------------------------------------------------
# sectools_select_falcon <repo dir> <el> <arch>
#
# Prefers the exact el<N>.<arch> build; CrowdStrike ships genuinely distinct
# per-EL sensors so no substitution happens unless FALCON_ALLOW_EL_FALLBACK=1,
# which walks down to the nearest lower EL build. FALCON_RPM overrides entirely.
# ------------------------------------------------------------------------------
sectools_select_falcon() {
  local repo="$1" el="$2" arch="$3"

  if [[ -n "${FALCON_RPM:-}" ]]; then
    [[ -f "$FALCON_RPM" ]] || {
      log "ERROR: FALCON_RPM override points at a missing file: $FALCON_RPM"
      return "$SECTOOLS_RC_PACKAGE"
    }
    printf '%s\n' "$FALCON_RPM"
    return 0
  fi

  local -a matches=() sorted=()
  local saved
  saved="$(shopt -p nullglob || true)"
  shopt -s nullglob
  matches=("${repo}"/falcon-sensor-*."el${el}"."${arch}".rpm)
  eval "$saved" 2>/dev/null || true

  if ((${#matches[@]} > 0)); then
    mapfile -t sorted < <(printf '%s\n' "${matches[@]}" | sort -V)
    printf '%s\n' "${sorted[-1]}"
    return 0
  fi

  log "ERROR: no CrowdStrike sensor staged for el${el} ${arch} in ${repo}"
  sectools_list_available "$repo" 'falcon-sensor-*.rpm'

  if [[ "${FALCON_ALLOW_EL_FALLBACK:-0}" != "1" ]]; then
    log "ERROR: refusing to substitute a different EL build; set FALCON_ALLOW_EL_FALLBACK=1 to allow the nearest lower EL sensor"
    return "$SECTOOLS_RC_PACKAGE"
  fi

  local candidate_el
  for ((candidate_el = el - 1; candidate_el >= 7; candidate_el--)); do
    saved="$(shopt -p nullglob || true)"
    shopt -s nullglob
    matches=("${repo}"/falcon-sensor-*."el${candidate_el}"."${arch}".rpm)
    eval "$saved" 2>/dev/null || true
    if ((${#matches[@]} > 0)); then
      mapfile -t sorted < <(printf '%s\n' "${matches[@]}" | sort -V)
      warn "FALCON_ALLOW_EL_FALLBACK=1: using the el${candidate_el} sensor on an el${el} host — confirm vendor support before relying on this"
      printf '%s\n' "${sorted[-1]}"
      return 0
    fi
  done

  log "ERROR: no CrowdStrike sensor available for ${arch} at or below el${el}"
  return "$SECTOOLS_RC_PACKAGE"
}

# ------------------------------------------------------------------------------
# sectools_select_tanium <repo dir> <el> <arch>
#
# Prefers the exact rhe<N>.<arch> filename so operator expectations hold. When
# that filename is absent (el7 aarch64 is not staged) it falls back to any
# staged package whose *header arch* matches, because the staged Tanium builds
# are glibc-keyed and identical across rheN filenames for a given architecture.
# TANIUM_RPM overrides entirely.
# ------------------------------------------------------------------------------
sectools_select_tanium() {
  local repo="$1" el="$2" arch="$3"

  if [[ -n "${TANIUM_RPM:-}" ]]; then
    [[ -f "$TANIUM_RPM" ]] || {
      log "ERROR: TANIUM_RPM override points at a missing file: $TANIUM_RPM"
      return "$SECTOOLS_RC_PACKAGE"
    }
    printf '%s\n' "$TANIUM_RPM"
    return 0
  fi

  local -a matches=() sorted=()
  local saved
  saved="$(shopt -p nullglob || true)"
  shopt -s nullglob
  matches=("${repo}"/TaniumClient-*."rhe${el}"."${arch}".rpm)
  eval "$saved" 2>/dev/null || true

  if ((${#matches[@]} > 0)); then
    mapfile -t sorted < <(printf '%s\n' "${matches[@]}" | sort -V)
    printf '%s\n' "${sorted[-1]}"
    return 0
  fi

  warn "no Tanium package named rhe${el}.${arch}; falling back to header-arch matching"

  saved="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local -a all=("${repo}"/TaniumClient-*.rpm)
  eval "$saved" 2>/dev/null || true

  local -a compatible=()
  local candidate candidate_arch
  for candidate in "${all[@]}"; do
    candidate_arch="$(sectools_rpm_field "$candidate" ARCH || true)"
    if [[ "$candidate_arch" == "$arch" || "$candidate_arch" == "noarch" ]]; then
      compatible+=("$candidate")
    fi
  done

  if ((${#compatible[@]} > 0)); then
    mapfile -t sorted < <(printf '%s\n' "${compatible[@]}" | sort -V)
    warn "selected Tanium package by header arch (${arch}): $(basename "${sorted[-1]}")"
    printf '%s\n' "${sorted[-1]}"
    return 0
  fi

  log "ERROR: no Tanium package staged for ${arch} in ${repo}"
  sectools_list_available "$repo" 'TaniumClient-*.rpm'
  return "$SECTOOLS_RC_PACKAGE"
}

# ------------------------------------------------------------------------------
# sectools_package_matrix <base dir> — staged inventory with real metadata
# ------------------------------------------------------------------------------
sectools_package_matrix() {
  local base="${1:-.}" f name evr arch digest

  printf '%-48s %-14s %-26s %-9s %s\n' FILE NAME VERSION-RELEASE ARCH DIGEST
  printf '%-48s %-14s %-26s %-9s %s\n' \
    '------------------------------------------------' '--------------' \
    '--------------------------' '---------' '------'

  local saved
  saved="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local -a all=("${base}"/crowdstrike/*.rpm "${base}"/tanium/*.rpm)
  eval "$saved" 2>/dev/null || true

  for f in "${all[@]}"; do
    name="$(sectools_rpm_field "$f" NAME || echo '?')"
    evr="$(rpm -qp --nosignature --qf '%{VERSION}-%{RELEASE}' "$f" 2>/dev/null || echo '?')"
    arch="$(sectools_rpm_field "$f" ARCH || echo '?')"
    if [[ "${SECTOOLS_SKIP_DIGEST:-0}" == "1" ]]; then
      digest='skipped'
    elif rpm -K --nosignature "$f" 2>&1 | grep -qi 'NOT OK'; then
      digest='CORRUPT'
    else
      digest='ok'
    fi
    printf '%-48s %-14s %-26s %-9s %s\n' "$(basename "$f")" "$name" "$evr" "$arch" "$digest"
  done
}

# ------------------------------------------------------------------------------
# Standalone CLI
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  _base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  case "${1:-report}" in
    report)
      sectools_detect_platform || exit $?
      _falcon="$(sectools_select_falcon "${_base}/crowdstrike" "$SECTOOLS_EL" "$SECTOOLS_ARCH")" || exit $?
      _tanium="$(sectools_select_tanium "${_base}/tanium" "$SECTOOLS_EL" "$SECTOOLS_ARCH")" || exit $?
      echo
      echo "Selected CrowdStrike : $(basename "$_falcon")"
      echo "Selected Tanium      : $(basename "$_tanium")"
      echo
      sectools_validate_rpm "$_falcon" falcon-sensor "$SECTOOLS_ARCH" || exit $?
      sectools_validate_rpm "$_tanium" TaniumClient "$SECTOOLS_ARCH" || exit $?
      ;;
    matrix)
      sectools_package_matrix "$_base"
      ;;
    select)
      [[ $# -eq 3 ]] || { echo "usage: $0 select <el-version> <arch>" >&2; exit "$SECTOOLS_RC_USAGE"; }
      sectools_select_falcon "${_base}/crowdstrike" "$2" "$3"
      sectools_select_tanium "${_base}/tanium" "$2" "$3"
      ;;
    *)
      echo "usage: $0 {report|matrix|select <el> <arch>}" >&2
      exit "$SECTOOLS_RC_USAGE"
      ;;
  esac
fi
