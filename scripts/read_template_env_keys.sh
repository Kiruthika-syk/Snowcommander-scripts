#!/usr/bin/env bash
# In-place template cycle: read AZCM_SP_CLIENT_ID + FALCON_CID, finalize, print TSV.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVISION="${BASE_DIR}/scripts/vsphere_provision.py"
ENV_FILE="${REMOTE_DIR:-/home/tpx-admin/2026snowcommander}/securitytools.env"

CREDS="${CREDS_FILE:-${BASE_DIR}/securitytools.env}"
JUMP="${JUMP_CREDS_FILE:-${BASE_DIR}/vcenter.env}"
[[ -r "$CREDS" ]] && { set -a; source "$CREDS"; set +a; }
[[ -r "$JUMP" ]] && { set -a; source "$JUMP"; set +a; }

read_one() {
  local vcenter="$1" template="$2" portgroup="$3"
  local json ip sp cid log="/tmp/read-env-$$-${template// /_}.log"

  json="$(python3 "$PROVISION" --vcenter "$vcenter" --template "$template" \
    --mode convert --i-understand-this-destroys-the-template \
    --portgroup "$portgroup" --allow-no-ip --insecure 2>"$log" \
    | python3 -c "import sys; lines=[l.strip() for l in sys.stdin if l.strip().startswith('{')]; print(lines[-1] if lines else '')")" \
    || json=""

  ip=""
  if [[ -n "$json" ]]; then
    ip="$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ip') or '')" 2>/dev/null || true)"
  fi

  sp=""; cid=""
  if [[ -n "$ip" ]]; then
    local n=0
    while (( n < 24 )); do
      sp="$(SSHPASS="$SSHPASS" sshpass -e ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -o ConnectTimeout=12 "tpx-admin@${ip}" \
        "grep -m1 '^AZCM_SP_CLIENT_ID=' '${ENV_FILE}' 2>/dev/null | cut -d= -f2-" 2>/dev/null || true)"
      cid="$(SSHPASS="$SSHPASS" sshpass -e ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -o ConnectTimeout=12 "tpx-admin@${ip}" \
        "grep -m1 '^FALCON_CID=' '${ENV_FILE}' 2>/dev/null | cut -d= -f2-" 2>/dev/null || true)"
      [[ -n "$sp" && -n "$cid" ]] && break
      sleep 10
      n=$((n + 1))
    done
  fi

  if [[ -z "$sp" || -z "$cid" ]]; then
    local gjson
    gjson="$(python3 "$PROVISION" --vcenter "$vcenter" --guest-read-env \
      --vm-name "$template" --env-guest-path "$ENV_FILE" \
      --env-keys AZCM_SP_CLIENT_ID,FALCON_CID --insecure 2>>"$log" \
      | python3 -c "import sys; lines=[l.strip() for l in sys.stdin if l.strip().startswith('{')]; print(lines[-1] if lines else '')")" \
      || gjson=""
    if [[ -n "$gjson" ]]; then
      sp="$(printf '%s' "$gjson" | python3 -c "import sys,json; print((json.load(sys.stdin).get('env_keys') or {}).get('AZCM_SP_CLIENT_ID',''))")"
      cid="$(printf '%s' "$gjson" | python3 -c "import sys,json; print((json.load(sys.stdin).get('env_keys') or {}).get('FALCON_CID',''))")"
    fi
  fi

  python3 "$PROVISION" --vcenter "$vcenter" --finalize "$template" --insecure >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\n' "$template" "${cid:-NOT_FOUND}" "${sp:-NOT_FOUND}"
}

read_one blr-vsphere-01.strykercorp.com BLR-GI-7.3 VLAN-126
read_one fw-vsphere-01.strykercorp.com FW-Redhat-10 fwa-vlan106
read_one fw-vsphere-01.strykercorp.com FW-GI-7.1 fwa-vlan106
