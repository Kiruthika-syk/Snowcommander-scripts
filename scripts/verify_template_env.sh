#!/usr/bin/env bash
# Verify AZCM_SP_CLIENT_ID + FALCON_CID on each SnowCommander template IN PLACE only.
# Same VM name throughout: template -> convert to VM -> read env -> finalize back.
# Never uses --mode clone and never creates verify-env-* (or any other) extra VMs.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/tpx-admin/2026snowcommander}"
ENV_FILE="${REMOTE_DIR}/securitytools.env"
PROVISION="${BASE_DIR}/scripts/vsphere_provision.py"
LOG_DIR="${VERIFY_LOG_DIR:-/tmp/verify-template-env.d}"
mkdir -p "$LOG_DIR"

CREDS="${CREDS_FILE:-${BASE_DIR}/securitytools.env}"
JUMP="${JUMP_CREDS_FILE:-${BASE_DIR}/vcenter.env}"
if [[ -r "$CREDS" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CREDS"; set +a
fi
if [[ -r "$JUMP" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$JUMP"; set +a
fi
EXPECTED_SP_CLIENT_ID="${EXPECTED_AZCM_SP_CLIENT_ID:-${AZCM_SP_CLIENT_ID:-}}"
EXPECTED_FALCON_CID="${EXPECTED_FALCON_CID:-${FALCON_CID:-}}"
[[ -n "$EXPECTED_SP_CLIENT_ID" && -n "$EXPECTED_FALCON_CID" ]] \
  || { echo "ERROR: expected AZCM_SP_CLIENT_ID and FALCON_CID not set on jump host" >&2; exit 2; }

declare -A SITE_VCENTER=(
  [blr]=blr-vsphere-01.strykercorp.com
  [fw]=fw-vsphere-01.strykercorp.com
  [stc]=stc-vsphere-01.strykercorp.com
)

declare -A SITE_PORTGROUP=(
  [blr]="${BLR_PORTGROUP:-VLAN-126}"
  [fw]="${FW_PORTGROUP:-fwa-vlan106}"
  [stc]="${STC_PORTGROUP:-stc-vlan847}"
)

[[ -n "${VCENTER_USER:-}" && -n "${VCENTER_PASSWORD:-}" ]] \
  || { echo "ERROR: set VCENTER_USER and VCENTER_PASSWORD (e.g. in vcenter.env)" >&2; exit 2; }
[[ -n "${SSHPASS:-}" ]] || { echo "ERROR: set SSHPASS for template SSH / Guest Operations" >&2; exit 2; }

command -v sshpass >/dev/null || { echo "ERROR: sshpass required" >&2; exit 2; }

RESTORE_VCENTER=""
RESTORE_TEMPLATE=""

finalize_template() {
  local vcenter="$1" template="$2"
  python3 "$PROVISION" --vcenter "$vcenter" --finalize "$template" \
    --insecure >>"${LOG_DIR}/finalize.log" 2>&1 || true
}

restore_template_if_needed() {
  local rc=$?
  if [[ -n "$RESTORE_VCENTER" && -n "$RESTORE_TEMPLATE" ]]; then
    echo "WARN: restoring ${RESTORE_TEMPLATE} to template form (exit=${rc})" >&2
    finalize_template "$RESTORE_VCENTER" "$RESTORE_TEMPLATE"
  fi
  RESTORE_VCENTER=""
  RESTORE_TEMPLATE=""
  return "$rc"
}

read_key_ssh() {
  local ip="$1" key="$2"
  SSHPASS="$SSHPASS" sshpass -e ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -o ConnectTimeout=15 "tpx-admin@${ip}" \
    "grep -m1 '^${key}=' '${ENV_FILE}' 2>/dev/null | cut -d= -f2-" 2>/dev/null || true
}

read_keys_guest() {
  local vcenter="$1" vm_name="$2"
  local json
  json="$(python3 "$PROVISION" --vcenter "$vcenter" \
    --guest-read-env --vm-name "$vm_name" --env-guest-path "$ENV_FILE" \
    --env-keys AZCM_SP_CLIENT_ID,FALCON_CID --insecure 2>>"${LOG_DIR}/guest.log" | tail -1)" \
    || return 1
  printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ek = d.get('env_keys') or {}
print(ek.get('AZCM_SP_CLIENT_ID', ''))
print(ek.get('FALCON_CID', ''))
"
}

verify_one() {
  local site="$1" template="$2"
  local vcenter="${SITE_VCENTER[$site]}"
  local portgroup="${SITE_PORTGROUP[$site]}"
  local slug log json ip sp cid sp_ok cid_ok status vm_name

  slug="$(echo "$template" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
  log="${LOG_DIR}/${site}-${slug}.log"

  RESTORE_VCENTER="$vcenter"
  RESTORE_TEMPLATE="$template"
  trap restore_template_if_needed EXIT

  if ! json="$(python3 "$PROVISION" \
    --vcenter "$vcenter" --template "$template" \
    --mode convert --i-understand-this-destroys-the-template \
    --portgroup "$portgroup" --allow-no-ip --insecure 2>"$log" | tail -1)"; then
    finalize_template "$vcenter" "$template"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$template" "ERROR" "convert/power" "-" "-"
    RESTORE_VCENTER=""
    RESTORE_TEMPLATE=""
    trap - EXIT
    return 0
  fi

  ip="$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ip') or '')" 2>/dev/null || true)"
  vm_name="$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vm_name') or '')" 2>/dev/null || true)"
  [[ -n "$vm_name" ]] || vm_name="$template"

  sp=""; cid=""
  if [[ -n "$ip" ]]; then
    local waited=0
    while (( waited < 180 )); do
      if SSHPASS="$SSHPASS" sshpass -e ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -o ConnectTimeout=5 "tpx-admin@${ip}" "test -r '${ENV_FILE}'" 2>/dev/null; then
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done
    sp="$(read_key_ssh "$ip" AZCM_SP_CLIENT_ID)"
    cid="$(read_key_ssh "$ip" FALCON_CID)"
  fi

  if [[ -z "$sp" || -z "$cid" ]]; then
    local guest_out
    if guest_out="$(read_keys_guest "$vcenter" "$vm_name" 2>/dev/null)"; then
      sp="$(printf '%s\n' "$guest_out" | sed -n '1p')"
      cid="$(printf '%s\n' "$guest_out" | sed -n '2p')"
    fi
  fi

  sp_ok=NO; cid_ok=NO
  [[ "$sp" == "$EXPECTED_SP_CLIENT_ID" ]] && sp_ok=YES
  [[ "$cid" == "$EXPECTED_FALCON_CID" ]] && cid_ok=YES

  if [[ "$sp_ok" == YES && "$cid_ok" == YES ]]; then
    status=OK
  elif [[ -z "$sp" && -z "$cid" ]]; then
    status=ERROR
    sp_ok="-"
    cid_ok="-"
  else
    status=MISMATCH
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$template" "$status" "$sp_ok" "$cid_ok" "${ip:-guest-ops}"

  finalize_template "$vcenter" "$template"

  RESTORE_VCENTER=""
  RESTORE_TEMPLATE=""
  trap - EXIT
}

printf 'EXPECTED_AZCM_SP_CLIENT_ID=%s\n' "$EXPECTED_SP_CLIENT_ID"
printf 'EXPECTED_FALCON_CID=%s\n' "$EXPECTED_FALCON_CID"
printf 'site\ttemplate\tstatus\tsp_match\tcid_match\tip\n'

for site in blr fw; do
  case "$site" in
    blr) templates=(BLR-Redhat-9 BLR-Redhat-10 BLR-GI-6.6 BLR-GI-7.1 BLR-GI-7.2 BLR-GI-7.3) ;;
    fw) templates=(FW-Redhat-9 FW-Redhat-10 FW-GI-6.6 FW-GI-7.1 FW-GI-7.2 FW-GI-7.3) ;;
  esac
  for t in "${templates[@]}"; do
    verify_one "$site" "$t"
  done
done
verify_one stc "SC-Redhat 9"
