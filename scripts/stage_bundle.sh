#!/usr/bin/env bash
# ==============================================================================
# stage_bundle.sh — build the minimal per-target deployment bundle
#
# Reads deploy-manifest.txt, adds exactly one CrowdStrike sensor and one Tanium
# client chosen for the target's EL version and architecture, and emits either a
# staging directory or a gzipped tarball on stdout.
#
# Usage:
#   scripts/stage_bundle.sh --el 9 --arch x86_64 --out /tmp/bundle
#   scripts/stage_bundle.sh --el 9 --arch x86_64 --tar > bundle.tar.gz
#   scripts/stage_bundle.sh --probe user@host --tar > bundle.tar.gz
#   scripts/stage_bundle.sh --el 9 --arch x86_64 --list
#
# Never includes securitytools.env: secrets travel on their own channel.
#
# Exit codes mirror lib/pkg_select.sh:
#   0 ok, 2 usage, 3 unsupported OS, 4 unsupported arch, 5 package failure
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${BASE_DIR}/deploy-manifest.txt"

# Emit logs on stderr so --tar can write the archive to stdout cleanly.
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*"; }

# shellcheck source=../lib/pkg_select.sh
source "${BASE_DIR}/lib/pkg_select.sh"

EL=""
ARCH=""
OUT=""
MODE="dir"
PROBE=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --el) EL="${2:?--el needs a value}"; shift 2 ;;
    --arch) ARCH="${2:?--arch needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; MODE="dir"; shift 2 ;;
    --tar) MODE="tar"; shift ;;
    --list) MODE="list"; shift ;;
    --probe) PROBE="${2:?--probe needs user@host}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit "$SECTOOLS_RC_USAGE" ;;
  esac
done

# Probe a live target over SSH when EL/arch were not supplied.
if [[ -n "$PROBE" ]]; then
  log "probing ${PROBE} for platform details"
  probe_out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$PROBE" \
    '. /etc/os-release; printf "%s %s %s\n" "${ID}" "${VERSION_ID%%.*}" "$(uname -m)"' 2>/dev/null)" || {
    err "cannot reach ${PROBE} over SSH"
    exit "$SECTOOLS_RC_USAGE"
  }
  read -r probe_id probe_major probe_arch <<<"$probe_out"

  mapping="$(sectools_os_to_el "$probe_id" "$probe_major" "")" || {
    err "target ${PROBE} runs an unsupported OS (ID=${probe_id}, major=${probe_major})"
    [[ "${mapping%% *}" == "debian" ]] \
      && err "no .deb packages exist in this repository; Debian/Ubuntu targets are not supported"
    exit "$SECTOOLS_RC_UNSUPPORTED_OS"
  }
  EL="${mapping##* }"
  ARCH="$(sectools_normalize_arch "$probe_arch")" || {
    err "target ${PROBE} reports unsupported architecture: ${probe_arch}"
    exit "$SECTOOLS_RC_UNSUPPORTED_ARCH"
  }
  log "probe result: el${EL} ${ARCH}"
fi

[[ -n "$EL" && -n "$ARCH" ]] || {
  err "--el and --arch are required (or use --probe user@host)"
  usage >&2
  exit "$SECTOOLS_RC_USAGE"
}

[[ -r "$MANIFEST" ]] || { err "manifest not found: $MANIFEST"; exit "$SECTOOLS_RC_USAGE"; }

# ------------------------------------------------------------------------------
# Resolve the two packages for this target before copying anything.
# ------------------------------------------------------------------------------
falcon_rpm="$(sectools_select_falcon "${BASE_DIR}/crowdstrike" "$EL" "$ARCH")" || exit "$SECTOOLS_RC_PACKAGE"
tanium_rpm="$(sectools_select_tanium "${BASE_DIR}/tanium" "$EL" "$ARCH")" || exit "$SECTOOLS_RC_PACKAGE"

sectools_validate_rpm "$falcon_rpm" falcon-sensor "$ARCH" || exit "$SECTOOLS_RC_PACKAGE"
sectools_validate_rpm "$tanium_rpm" TaniumClient "$ARCH" || exit "$SECTOOLS_RC_PACKAGE"

# ------------------------------------------------------------------------------
# Read the manifest.
# ------------------------------------------------------------------------------
declare -a REQUIRED=() OPTIONAL=()
# Override the script-wide IFS here: it excludes space, which would otherwise
# swallow the whole "<class> <path>" line into the first variable.
while IFS=$' \t' read -r class path _rest; do
  [[ -z "${class:-}" || -z "${path:-}" ]] && continue
  case "$class" in
    required) REQUIRED+=("$path") ;;
    optional) OPTIONAL+=("$path") ;;
    *) warn "manifest: ignoring unknown class '${class}' for ${path}" ;;
  esac
done < <(sed 's/#.*//' "$MANIFEST")

((${#REQUIRED[@]} > 0)) || { err "manifest declares no required files: $MANIFEST"; exit "$SECTOOLS_RC_PACKAGE"; }

missing=0
for f in "${REQUIRED[@]}"; do
  [[ -f "${BASE_DIR}/${f}" ]] || { err "manifest requires a missing file: ${f}"; missing=1; }
done
((missing == 0)) || exit "$SECTOOLS_RC_PACKAGE"

# ------------------------------------------------------------------------------
# --list: show the contents without building anything.
# ------------------------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
  printf 'Bundle contents for el%s %s:\n\n' "$EL" "$ARCH"
  for f in "${REQUIRED[@]}"; do printf '  %-10s %s\n' REQUIRED "$f"; done
  echo
  for f in "${OPTIONAL[@]}"; do
    if [[ -f "${BASE_DIR}/${f}" ]]; then
      printf '  %-10s %s\n' OPTIONAL "$f"
    else
      printf '  %-10s %s (absent, skipped)\n' OPTIONAL "$f"
    fi
  done
  echo
  printf '  %-10s crowdstrike/%s\n' PACKAGE "$(basename "$falcon_rpm")"
  printf '  %-10s tanium/%s\n' PACKAGE "$(basename "$tanium_rpm")"
  echo
  printf '  %-10s securitytools.env (pushed separately over SSH, never bundled)\n' EXCLUDED
  exit 0
fi

# ------------------------------------------------------------------------------
# Build the staging tree.
# ------------------------------------------------------------------------------
if [[ "$MODE" == "tar" ]]; then
  OUT="$(mktemp -d)"
  trap 'rm -rf "$OUT"' EXIT
else
  [[ -n "$OUT" ]] || { err "--out is required unless --tar or --list is used"; exit "$SECTOOLS_RC_USAGE"; }
  mkdir -p "$OUT"
fi

copy_into() {
  local rel="$1" dest="${OUT}/${1}"
  mkdir -p "$(dirname "$dest")"
  cp -p "${BASE_DIR}/${rel}" "$dest"
}

for f in "${REQUIRED[@]}"; do copy_into "$f"; done
for f in "${OPTIONAL[@]}"; do
  [[ -f "${BASE_DIR}/${f}" ]] && copy_into "$f" || warn "optional file absent, skipping: ${f}"
done

mkdir -p "${OUT}/crowdstrike" "${OUT}/tanium"
cp -p "$falcon_rpm" "${OUT}/crowdstrike/"
cp -p "$tanium_rpm" "${OUT}/tanium/"

# Guard against a secrets file ever reaching a target inside the bundle.
if find "$OUT" -name 'securitytools.env' -print -quit | grep -q .; then
  err "refusing to emit a bundle containing securitytools.env"
  exit "$SECTOOLS_RC_PACKAGE"
fi

chmod 0755 "${OUT}/security.sh" "${OUT}/lib/pkg_select.sh" "${OUT}/sentinel_core.sh"
find "$OUT" -name '*.sh' -exec chmod 0755 {} +
chmod 0600 "${OUT}/tanium/tanium-init.dat"

bundle_size="$(du -sh "$OUT" | cut -f1)"
file_count="$(find "$OUT" -type f | wc -l)"
log "bundle ready: ${file_count} files, ${bundle_size} (el${EL} ${ARCH})"

if [[ "$MODE" == "tar" ]]; then
  tar -C "$OUT" -czf - .
else
  log "staged at ${OUT}"
  printf '%s\n' "$OUT"
fi
