#!/usr/bin/env bash
# ==============================================================================
# deploy_targets.sh — SSH fan-out orchestrator
#
# Runs on the control plane (container or jump host), never on a target. For
# each target it probes the platform, stages a bundle matched to that host's
# EL version and architecture, pushes it, runs security.sh over SSH, then
# collects per-component status.
#
# Usage:
#   scripts/deploy_targets.sh --hosts h1,h2 --mode plan
#   scripts/deploy_targets.sh --inventory /etc/inventory --mode deploy --components all
#   scripts/deploy_targets.sh --inventory /etc/inventory --mode verify --parallel 10
#
# Secrets come from the environment (FALCON_CID, FALCON_PROVISIONING_TOKEN,
# CMDBSYNC_PASSWORD, AZCM_*, ...). They are rendered once to a 0600 file,
# pushed to each target on a separate SSH channel, and shredded afterwards.
# They are never placed on a command line, so `ps` cannot reveal them.
#
# Exit codes:
#    0  every host and component succeeded
#    2  usage error
#   20  partial — at least one host or component failed
#   21  every host failed
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/var/tmp/sectools}"

MODE=plan
COMPONENTS=all
SSH_USER="${SSH_USER:-tpx-admin}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
PARALLEL="${PARALLEL:-5}"
RETRIES="${RETRIES:-1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
KEEP_REMOTE=0
declare -a HOSTS=()

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2; }
die() { err "$*"; exit 2; }

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)
      IFS=',' read -r -a _h <<<"${2:?--hosts needs a value}"
      HOSTS+=("${_h[@]}")
      shift 2
      ;;
    --inventory)
      inv="${2:?--inventory needs a path}"
      [[ -r "$inv" ]] || die "inventory not readable: $inv"
      while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && HOSTS+=("$line")
      done <"$inv"
      shift 2
      ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --components) COMPONENTS="${2:?}"; shift 2 ;;
    --user) SSH_USER="${2:?}"; shift 2 ;;
    --port) SSH_PORT="${2:?}"; shift 2 ;;
    --key) SSH_KEY="${2:?}"; shift 2 ;;
    --parallel) PARALLEL="${2:?}"; shift 2 ;;
    --retries) RETRIES="${2:?}"; shift 2 ;;
    --keep-remote) KEEP_REMOTE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  plan | verify | deploy) : ;;
  *) die "--mode must be plan, verify or deploy (got '$MODE')" ;;
esac

((${#HOSTS[@]} > 0)) || die "no targets: pass --hosts or --inventory"
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || die "--parallel must be a positive integer"

# Reject obviously malformed hostnames before they reach ssh.
for h in "${HOSTS[@]}"; do
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid hostname in inventory: '$h'"
done

# ------------------------------------------------------------------------------
# SSH options
# ------------------------------------------------------------------------------
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -p "$SSH_PORT"
)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
# Honour a mounted known_hosts; otherwise trust on first use and say so.
if [[ -r "${HOME}/.ssh/known_hosts" ]]; then
  SSH_OPTS+=(-o StrictHostKeyChecking=yes)
else
  SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
  log "NOTE: no ~/.ssh/known_hosts present; host keys are trusted on first use"
fi

# ------------------------------------------------------------------------------
# Render the secrets file once. 0600, shredded on exit.
# ------------------------------------------------------------------------------
ENVFILE="$(mktemp)"
RESULT_DIR="$(mktemp -d)"
cleanup() {
  shred -u "$ENVFILE" 2>/dev/null || rm -f "$ENVFILE"
  rm -rf "$RESULT_DIR"
}
trap cleanup EXIT
chmod 600 "$ENVFILE"

{
  printf 'FALCON_CID=%s\n' "${FALCON_CID:-}"
  printf 'FALCON_PROVISIONING_TOKEN=%s\n' "${FALCON_PROVISIONING_TOKEN:-}"
  printf 'CMDBSYNC_PASSWORD=%s\n' "${CMDBSYNC_PASSWORD:-}"
  printf 'CMDBSYNC_UID=%s\n' "${CMDBSYNC_UID:-2800}"
  printf 'CMDBSYNC_GID=%s\n' "${CMDBSYNC_GID:-1700}"
  printf 'AZCM_SP_CLIENT_ID=%s\n' "${AZCM_SP_CLIENT_ID:-}"
  printf 'AZCM_SP_SECRET=%s\n' "${AZCM_SP_SECRET:-}"
  printf 'AZCM_SUBSCRIPTION_ID=%s\n' "${AZCM_SUBSCRIPTION_ID:-}"
  printf 'AZCM_TENANT_ID=%s\n' "${AZCM_TENANT_ID:-}"
  printf 'AZCM_RESOURCE_GROUP=%s\n' "${AZCM_RESOURCE_GROUP:-}"
  printf 'AZCM_LOCATION=%s\n' "${AZCM_LOCATION:-eastus2}"
  printf 'AZCM_CLOUD=%s\n' "${AZCM_CLOUD:-AzureCloud}"
  printf 'AZCM_TAGS=%s\n' "${AZCM_TAGS:-Environment=Production}"
  printf 'SYSLOG_SERVER1=%s\n' "${SYSLOG_SERVER1:-10.132.118.100}"
  printf 'SYSLOG_SERVER2=%s\n' "${SYSLOG_SERVER2:-10.50.118.100}"
  printf 'SYSLOG_PORT=%s\n' "${SYSLOG_PORT:-514}"
  [[ -n "${CMDBSYNC_FORCE_PASSWORD:-}" ]] && printf 'CMDBSYNC_FORCE_PASSWORD=%s\n' "$CMDBSYNC_FORCE_PASSWORD"
  [[ -n "${SENTINEL_FORCE_RECONNECT:-}" ]] && printf 'SENTINEL_FORCE_RECONNECT=%s\n' "$SENTINEL_FORCE_RECONNECT"
} >"$ENVFILE"

# deploy mode needs a CID; plan and verify do not.
if [[ "$MODE" == "deploy" && -z "${FALCON_CID:-}" ]]; then
  case "$COMPONENTS" in
    *crowdstrike* | all) die "FALCON_CID is not set but the crowdstrike component was requested" ;;
  esac
fi

# ------------------------------------------------------------------------------
# Per-host worker. Writes TSV rows to $RESULT_DIR/<host>.tsv:
#   host <TAB> component <TAB> status <TAB> detail
# ------------------------------------------------------------------------------
deploy_one_host() {
  local host="$1"
  local out="${RESULT_DIR}/${host}.tsv"
  local logf="${RESULT_DIR}/${host}.log"
  local target="${SSH_USER}@${host}"
  local attempt rc

  record() { printf '%s\t%s\t%s\t%s\n' "$host" "$1" "$2" "$3" >>"$out"; }

  : >"$out"
  : >"$logf"

  if ! ssh "${SSH_OPTS[@]}" "$target" true 2>>"$logf"; then
    record '-' UNREACHABLE 'ssh connection failed'
    return 1
  fi
  if ! ssh "${SSH_OPTS[@]}" "$target" 'sudo -n true' 2>>"$logf"; then
    record '-' NO_SUDO 'passwordless sudo unavailable'
    return 1
  fi

  # Bundle is matched to this host's detected EL version and architecture.
  local bundle="${RESULT_DIR}/${host}.tar.gz"
  if ! "${BASE_DIR}/scripts/stage_bundle.sh" \
    --probe "$target" --tar >"$bundle" 2>>"$logf"; then
    record '-' STAGE_FAILED "$(tail -1 "$logf" | tr '\t' ' ' | cut -c1-120)"
    return 1
  fi

  ssh "${SSH_OPTS[@]}" "$target" \
    "rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}" 2>>"$logf"
  ssh "${SSH_OPTS[@]}" "$target" \
    "tar -C ${REMOTE_DIR} -xzf -" <"$bundle" 2>>"$logf"
  rm -f "$bundle"

  # Secrets on their own channel, straight into a 0600 file.
  ssh "${SSH_OPTS[@]}" "$target" \
    "umask 077; cat > ${REMOTE_DIR}/securitytools.env" <"$ENVFILE" 2>>"$logf"

  local remote_args
  case "$MODE" in
    plan) remote_args=plan ;;
    verify) remote_args=verify ;;
    deploy) remote_args="$COMPONENTS" ;;
  esac

  rc=0
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    rc=0
    ssh "${SSH_OPTS[@]}" "$target" \
      "sudo ${REMOTE_DIR}/security.sh ${remote_args}" >>"$logf" 2>&1 || rc=$?
    # security.sh is idempotent, so a retry re-converges only what failed.
    [[ $rc -eq 0 ]] && break
    ((attempt < RETRIES)) && log "${host}: attempt ${attempt} exited ${rc}, retrying"
  done

  # Always remove the secrets file, even after a failure.
  if ((KEEP_REMOTE == 0)); then
    ssh "${SSH_OPTS[@]}" "$target" \
      "shred -u ${REMOTE_DIR}/securitytools.env 2>/dev/null || rm -f ${REMOTE_DIR}/securitytools.env" \
      2>>"$logf" || log "${host}: WARNING could not remove securitytools.env"
  fi

  if grep -q '^###SECTOOLS_STATUS_BEGIN' "$logf"; then
    local overall
    overall="$(sed -n 's/^overall=//p' "$logf" | tail -1)"
    if grep -q '^component=' "$logf"; then
      while IFS= read -r line; do
        record \
          "$(sed -n 's/^component=\([^ ]*\).*/\1/p' <<<"$line")" \
          "$(sed -n 's/.*status=\([^ ]*\).*/\1/p' <<<"$line")" \
          "$(sed -n 's/.*detail=//p' <<<"$line")"
      done < <(grep '^component=' "$logf")
    else
      # plan emits platform facts rather than component rows.
      record plan "${overall:-UNKNOWN}" \
        "el$(sed -n 's/^el=//p' "$logf" | tail -1) $(sed -n 's/^arch=//p' "$logf" | tail -1) -> $(sed -n 's/^falcon_package=//p' "$logf" | tail -1)"
    fi
    [[ "$overall" == "SUCCESS" ]] && return 0 || return 1
  fi

  record '-' NO_STATUS "security.sh exited ${rc} without a status block"
  return 1
}

# ------------------------------------------------------------------------------
# Fan out with bounded concurrency.
# ------------------------------------------------------------------------------
log "mode=${MODE} components=${COMPONENTS} hosts=${#HOSTS[@]} parallel=${PARALLEL} retries=${RETRIES}"

running=0
for host in "${HOSTS[@]}"; do
  while ((running >= PARALLEL)); do
    wait -n 2>/dev/null || true
    ((running--)) || true
  done
  deploy_one_host "$host" &
  ((running++)) || true
done
wait

# ------------------------------------------------------------------------------
# Aggregate.
# ------------------------------------------------------------------------------
ALL="${RESULT_DIR}/all.tsv"
cat "${RESULT_DIR}"/*.tsv 2>/dev/null | sort >"$ALL" || true

hosts_ok=0
hosts_bad=0
for host in "${HOSTS[@]}"; do
  f="${RESULT_DIR}/${host}.tsv"
  if [[ -s "$f" ]] && ! awk -F'\t' '$3 !~ /^(SUCCESS|UNCHANGED|NOT_INSTALLED)$/ {found=1} END{exit !found}' "$f"; then
    ((hosts_ok++)) || true
  else
    ((hosts_bad++)) || true
  fi
done

echo
echo "=============================================================================="
printf ' %-30s %-13s %-13s %s\n' HOST COMPONENT STATUS DETAIL
echo "------------------------------------------------------------------------------"
if [[ -s "$ALL" ]]; then
  while IFS=$'\t' read -r h c s d; do
    printf ' %-30s %-13s %-13s %s\n' "$h" "$c" "$s" "${d:0:60}"
  done <"$ALL"
else
  echo ' (no results)'
fi
echo "=============================================================================="
printf ' %s host(s) clean, %s host(s) with failures   mode=%s\n' "$hosts_ok" "$hosts_bad" "$MODE"
echo "=============================================================================="

# Emit per-host logs for any failure so operators can act without re-running.
if ((hosts_bad > 0)); then
  echo
  for host in "${HOSTS[@]}"; do
    f="${RESULT_DIR}/${host}.tsv"
    [[ -s "$f" ]] || continue
    if awk -F'\t' '$3 !~ /^(SUCCESS|UNCHANGED|NOT_INSTALLED)$/ {found=1} END{exit !found}' "$f"; then
      echo "----- ${host}: last 25 log lines -----"
      tail -25 "${RESULT_DIR}/${host}.log" 2>/dev/null | sed 's/^/  /'
      echo
    fi
  done
fi

((hosts_bad == 0)) && exit 0
((hosts_ok == 0)) && exit 21
exit 20
