#!/usr/bin/env bash
# ==============================================================================
# e2e_validate.sh - end-to-end validation harness
#
# Proves the deployment automation works against a pristine VM built from a
# vSphere template, then leaves the VM clean with only the scripts in place.
#
# Eight stages, each logged explicitly:
#   1. connect to vSphere
#   2. find the template
#   3. produce a VM from the template, connect the NIC, power on, get an IP
#   4. place the scripts on the VM
#   5. install the security tools
#   6. verify service status with systemctl
#   7. uninstall the tools
#   8. confirm the scripts still exist in the placed directory
#
# Runs on the jump host, not inside the container: it needs pyvmomi for the
# vSphere stages and sshpass for templates that only allow password auth.
# The container remains the right tool for production fleet deploys over keys.
#
# Credentials, all from the environment, never from the command line:
#   VCENTER_USER / VCENTER_PASSWORD     vSphere
#   TARGET_SSH_USER                     login on the new VM (default tpx-admin)
#   SSHPASS                             target password (if no key)
#   TARGET_SSH_KEY                      private key path (preferred over SSHPASS)
#   FALCON_CID, CMDBSYNC_PASSWORD, AZCM_*, RHSM_USERNAME, RHSM_PASSWORD
#
# Usage:
#   scripts/e2e_validate.sh --vcenter blr-vsphere-01.strykercorp.com \
#       --template BLR-Redhat-9 --name e2e-test-rhel9 \
#       --portgroup 'VM Network' --insecure
#
#   # Full round trip on the template itself (no new VM is created):
#   scripts/e2e_validate.sh --vcenter fw-vsphere-01.strykercorp.com \
#       --template FW-Redhat-9 --template-cycle \
#       --portgroup 'fwa-vlan106' --fqdn-domain vcraeng.com --insecure
#
#   scripts/e2e_validate.sh ... --existing-host blr-gi-6   # skip stages 1-3
#   scripts/e2e_validate.sh ... --keep-tools               # skip stage 7
#   scripts/e2e_validate.sh ... --remote-dir /opt/foo      # script location
#
# --template-cycle is shorthand for:
#     --mode convert --i-understand-this-destroys-the-template
#     --convert-to-template
# It converts the template into a VM, validates, then converts it back.
#
# Exit codes: 0 all stages passed, 2 usage, 3x stage failure (30+stage number)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where the scripts live on the target.
#
# /opt is the default rather than /var/tmp because these survive into a golden
# image: systemd-tmpfiles cleans /var/tmp on a schedule (30 days on RHEL), so
# scripts placed there would silently disappear from a template that sits
# unused. Override with --remote-dir.
REMOTE_DIR="${REMOTE_DIR:-/opt/snowcommander}"

VCENTER=""
TEMPLATE=""
VM_NAME=""
PORTGROUP=""
DATASTORE=""
MODE=clone
CONFIRM_DESTROY=0
INSECURE=""
EXISTING_HOST=""
KEEP_TOOLS=0
KEEP_VM=0
IP_TIMEOUT=300
# sshd often starts after VMware Tools first reports an address.
SSH_WAIT="${SSH_WAIT:-120}"
COMPONENTS=all

# Which components stage 7 tears down. The three agents are removed; the
# cmdbsync account and the Red Hat subscription are deliberately retained,
# so the resulting template keeps its CMDB identity and entitlement.
UNINSTALL_COMPONENTS="${UNINSTALL_COMPONENTS:-tanium crowdstrike sentinel}"

# RHSM handling:
#   auto    infer from the template/guest - Red Hat templates keep the
#           subscription, GI/Vocera appliance templates are unregistered again
#   keep    register and leave the host registered
#   remove  register for the install, then unregister before finishing
#   skip    do not touch subscription-manager at all
RHSM_MODE=auto
RHSM_APPLIED=0

# Legacy payloads baked into the templates. These carry superseded scripts and,
# in at least one case, a truncated Falcon RPM that fails to install. They are
# removed so nobody runs them by hand after the new bundle lands.
# Append an FQDN entry to /etc/hosts on the target. The clone keeps the
# template's own hostname and IP because no guest customization is applied,
# so this only makes the fully-qualified name resolvable.
FQDN_DOMAIN=""
# Convert the VM back into a template once validation and teardown finish.
CONVERT_TO_TEMPLATE=0

PURGE_LEGACY=1
LEGACY_PATHS=(
  '$HOME/2026snowcommander'
  '/home/tpx-admin/2026snowcommander'
  '/root/2026snowcommander'
  '/opt/2026snowcommander'
)

TARGET_SSH_USER="${TARGET_SSH_USER:-tpx-admin}"
TARGET_SSH_KEY="${TARGET_SSH_KEY:-}"

# ------------------------------------------------------------------------------
# Logging: every stage transition is explicit and timestamped.
# ------------------------------------------------------------------------------
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
[[ -t 1 ]] || { C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; }

declare -A STAGE_RESULT=()
declare -A STAGE_DETAIL=()
CURRENT_STAGE=0
TARGET_IP=""
TARGET_HOST=""
created_vm=""
# Track the convert/restore round trip so a mid-run failure cannot leave the
# golden image stranded as a virtual machine.
TEMPLATE_CONVERTED=0
FINALIZED=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
say() { printf '[%s] %s\n' "$(ts)" "$*"; }
info() { printf '[%s]   %s\n' "$(ts)" "$*"; }

stage_begin() {
  CURRENT_STAGE="$1"
  printf '\n%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '%s STAGE %s/8 - %s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"
  printf '%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
}

stage_pass() {
  STAGE_RESULT["$CURRENT_STAGE"]=PASS
  STAGE_DETAIL["$CURRENT_STAGE"]="${1:-}"
  printf '%s[%s]   STAGE %s PASS%s - %s\n' "$C_GREEN" "$(ts)" "$CURRENT_STAGE" "$C_RESET" "${1:-}"
}

stage_fail() {
  STAGE_RESULT["$CURRENT_STAGE"]=FAIL
  STAGE_DETAIL["$CURRENT_STAGE"]="${1:-}"
  printf '%s[%s]   STAGE %s FAIL%s - %s\n' "$C_RED" "$(ts)" "$CURRENT_STAGE" "$C_RESET" "${1:-}"
  summary
  exit $((30 + CURRENT_STAGE))
}

stage_skip() {
  STAGE_RESULT["$CURRENT_STAGE"]=SKIP
  STAGE_DETAIL["$CURRENT_STAGE"]="${1:-}"
  printf '%s[%s]   STAGE %s SKIP%s - %s\n' "$C_YELLOW" "$(ts)" "$CURRENT_STAGE" "$C_RESET" "${1:-}"
}

die() { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 2; }

# If the run ends before finalisation and we converted a template in place,
# convert it back. Without this, any failure after stage 3 leaves the template
# as a VM and an operator has to remember to fix it by hand.
restore_template_on_exit() {
  local rc=$?
  if ((CONVERT_TO_TEMPLATE)) && ((TEMPLATE_CONVERTED)) && ((! FINALIZED)); then
    printf '\n%s[%s] run ended early (rc=%s) - restoring %s to template form%s\n' \
      "$C_YELLOW" "$(ts)" "$rc" "$created_vm" "$C_RESET"
    local args=(--vcenter "$VCENTER" --finalize "$created_vm")
    [[ -n "$INSECURE" ]] && args+=("$INSECURE")
    if python3 "${BASE_DIR}/scripts/vsphere_provision.py" "${args[@]}" >/dev/null 2>&1; then
      printf '%s[%s] %s restored to template%s\n' "$C_GREEN" "$(ts)" "$created_vm" "$C_RESET"
    else
      printf '%s[%s] AUTOMATIC RESTORE FAILED - convert %s back manually in vCenter%s\n' \
        "$C_RED" "$(ts)" "$created_vm" "$C_RESET"
    fi
  fi
  return $rc
}
trap restore_template_on_exit EXIT

# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vcenter) VCENTER="${2:?}"; shift 2 ;;
    --template) TEMPLATE="${2:?}"; shift 2 ;;
    --name) VM_NAME="${2:?}"; shift 2 ;;
    --portgroup) PORTGROUP="${2:?}"; shift 2 ;;
    --datastore) DATASTORE="${2:?}"; shift 2 ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --i-understand-this-destroys-the-template) CONFIRM_DESTROY=1; shift ;;
    --insecure) INSECURE=--insecure; shift ;;
    --existing-host) EXISTING_HOST="${2:?}"; shift 2 ;;
    --components) COMPONENTS="${2:?}"; shift 2 ;;
    --keep-tools) KEEP_TOOLS=1; shift ;;
    --keep-vm) KEEP_VM=1; shift ;;
    --rhsm-mode) RHSM_MODE="${2:?}"; shift 2 ;;
    --keep-legacy) PURGE_LEGACY=0; shift ;;
    --fqdn-domain) FQDN_DOMAIN="${2:?}"; shift 2 ;;
    --convert-to-template) CONVERT_TO_TEMPLATE=1; shift ;;
    --remote-dir) REMOTE_DIR="${2:?}"; shift 2 ;;
    --template-cycle)
      # Full round trip on the template itself:
      #   template -> VM -> place -> install -> verify -> uninstall -> template
      # Naming the flag after the whole cycle makes the destructive middle
      # step explicit, so no separate acknowledgement flag is required.
      MODE=convert
      CONFIRM_DESTROY=1
      CONVERT_TO_TEMPLATE=1
      shift
      ;;
    --ip-timeout) IP_TIMEOUT="${2:?}"; shift 2 ;;
    --ssh-wait) SSH_WAIT="${2:?}"; shift 2 ;;
    --uninstall-components) UNINSTALL_COMPONENTS="${2:?}"; shift 2 ;;
    --user) TARGET_SSH_USER="${2:?}"; shift 2 ;;
    --key) TARGET_SSH_KEY="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -z "$EXISTING_HOST" ]]; then
  [[ -n "$VCENTER" ]] || die "--vcenter is required (or use --existing-host to skip stages 1-3)"
  [[ -n "$TEMPLATE" ]] || die "--template is required"
  [[ "$MODE" == "convert" || -n "$VM_NAME" ]] || die "--name is required in clone mode"
fi

# ------------------------------------------------------------------------------
# SSH plumbing. Prefer a key; fall back to SSHPASS for fresh templates that
# only permit password login.
# ------------------------------------------------------------------------------
SSH_BASE=()
SSH_WRAP=()

configure_ssh_auth() {
  local common=(
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  )

  if [[ -n "$TARGET_SSH_KEY" ]]; then
    [[ -r "$TARGET_SSH_KEY" ]] || die "key not readable: $TARGET_SSH_KEY"
    SSH_BASE=(-o BatchMode=yes "${common[@]}" -i "$TARGET_SSH_KEY")
    info "target auth: public key ($TARGET_SSH_KEY)"
  elif [[ -n "${SSHPASS:-}" ]]; then
    command -v sshpass >/dev/null || die "SSHPASS is set but sshpass is not installed"
    # BatchMode must NOT be set here. It suppresses password prompting
    # entirely, which is exactly what sshpass needs in order to answer.
    SSH_BASE=("${common[@]}"
              -o PubkeyAuthentication=no
              -o PreferredAuthentications=password
              -o NumberOfPasswordPrompts=1)
    # sshpass reads the password from $SSHPASS, so it never reaches the
    # process table.
    SSH_WRAP=(sshpass -e)
    info "target auth: password via SSHPASS"
  else
    die "no target credentials: set TARGET_SSH_KEY or SSHPASS"
  fi
}

# Report why a connection failed instead of just that it did.
diagnose_ssh() {
  local host="$1" out
  info "diagnosing the SSH failure"
  if ! timeout 8 bash -c "</dev/tcp/${host}/22" 2>/dev/null; then
    info "  port 22 is not accepting connections (sshd down, or firewalled)"
    return
  fi
  info "  port 22 is open"
  out="$("${SSH_WRAP[@]}" ssh "${SSH_BASE[@]}" -o ConnectTimeout=10 \
        "${TARGET_SSH_USER}@${host}" true 2>&1 || true)"
  [[ -n "$out" ]] && printf '      %s\n' "$out" | head -5
  case "$out" in
    *"Permission denied"*)
      info "  authentication rejected - wrong password, or the account does not exist"
      info "  check: does '${TARGET_SSH_USER}' exist on this template?" ;;
    *"Connection refused"*) info "  sshd is not listening" ;;
    *"Too many authentication failures"*) info "  server rejected the attempt sequence" ;;
  esac
}

rsh() { "${SSH_WRAP[@]}" ssh "${SSH_BASE[@]}" "${TARGET_SSH_USER}@${TARGET_HOST}" "$@"; }
rsh_in() { "${SSH_WRAP[@]}" ssh "${SSH_BASE[@]}" "${TARGET_SSH_USER}@${TARGET_HOST}" "$@"; }

# Run a command as root on the target, using sudo -n or sudo -S as available.
rsudo() {
  if [[ -n "${SSHPASS:-}" && -z "$TARGET_SSH_KEY" ]]; then
    rsh "sudo -n $* 2>/dev/null || { printf '%s\\n' \"\$SUDOPW\" | sudo -S -p '' $*; }"
  else
    rsh "sudo -n $*"
  fi
}

summary() {
  local names=(
    [1]="connect to vSphere"
    [2]="find the template"
    [3]="template -> VM, NIC, power on"
    [4]="place the scripts"
    [5]="install the tools"
    [6]="verify with systemctl"
    [7]="uninstall the tools"
    [8]="confirm scripts remain"
  )
  printf '\n%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '%s END-TO-END VALIDATION SUMMARY%s\n' "$C_BOLD" "$C_RESET"
  printf '%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
  printf ' %-6s %-34s %-6s %s\n' STAGE DESCRIPTION RESULT DETAIL
  printf ' %-6s %-34s %-6s %s\n' '-----' '---------------------------------' '------' '--------------------'
  local i r colour
  for i in 1 2 3 4 5 6 7 8; do
    r="${STAGE_RESULT[$i]:-NOT_RUN}"
    case "$r" in
      PASS) colour="$C_GREEN" ;;
      FAIL) colour="$C_RED" ;;
      SKIP) colour="$C_YELLOW" ;;
      *) colour="" ;;
    esac
    printf ' %-6s %-34s %s%-6s%s %s\n' "$i" "${names[$i]}" "$colour" "$r" "$C_RESET" "${STAGE_DETAIL[$i]:-}"
  done
  printf '%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
  [[ -n "$TARGET_HOST" ]] && printf ' target: %s   scripts: %s\n' "$TARGET_HOST" "$REMOTE_DIR"
  printf '\n'
}

# ==============================================================================
# Stages 1-3 - vSphere
# ==============================================================================
if [[ -n "$EXISTING_HOST" ]]; then
  TARGET_HOST="$EXISTING_HOST"
  for s in 1 2 3; do
    CURRENT_STAGE=$s
    stage_skip "using existing host ${EXISTING_HOST}"
  done
else
  [[ -n "${VCENTER_USER:-}" && -n "${VCENTER_PASSWORD:-}" ]] \
    || die "set VCENTER_USER and VCENTER_PASSWORD in the environment"

  stage_begin 1 "CONNECT TO VSPHERE"
  info "vCenter: ${VCENTER}"
  info "user:    ${VCENTER_USER}"

  stage_begin 2 "FIND THE TEMPLATE"
  info "template: ${TEMPLATE}"

  stage_begin 3 "CONVERT TEMPLATE TO VM, CONNECT NIC, POWER ON"
  [[ "$MODE" == "convert" ]] \
    && info "mode: CONVERT (destructive - the template will cease to exist)" \
    || info "mode: clone (template preserved) -> ${VM_NAME}"

  # No --folder filter here. The scope guardrail already confines the search to
  # SnowCommander/Template(s), and sites differ on singular vs plural, so a
  # hardcoded 'Templates' silently excluded every FW template.
  provision_args=(--vcenter "$VCENTER" --template "$TEMPLATE" --mode "$MODE"
                  --ip-timeout "$IP_TIMEOUT")
  [[ -n "$VM_NAME" ]] && provision_args+=(--name "$VM_NAME")
  [[ -n "$PORTGROUP" ]] && provision_args+=(--portgroup "$PORTGROUP")
  [[ -n "$DATASTORE" ]] && provision_args+=(--datastore "$DATASTORE")
  [[ -n "$INSECURE" ]] && provision_args+=("$INSECURE")
  ((CONFIRM_DESTROY)) && provision_args+=(--i-understand-this-destroys-the-template)

  # stdout carries JSON; stderr carries the staged progress log.
  # Capture the status directly: inside `if ! cmd; then`, $? reflects the
  # negation and always reads 0, which masked the real exit code.
  rc=0
  result_json="$(python3 "${BASE_DIR}/scripts/vsphere_provision.py" "${provision_args[@]}")" || rc=$?
  if ((rc != 0)); then
    case $rc in
      2) CURRENT_STAGE=1; stage_fail "usage error invoking the provisioner (rc=2)" ;;
      3) CURRENT_STAGE=1; stage_fail "could not connect to vCenter (rc=3)" ;;
      4) CURRENT_STAGE=2; stage_fail "template '${TEMPLATE}' not found in scope (rc=4)" ;;
      5) CURRENT_STAGE=3; stage_fail "clone or NIC reconfigure failed (rc=5)" ;;
      6) CURRENT_STAGE=3; stage_fail "powered on but no IP address appeared (rc=6)" ;;
      7) CURRENT_STAGE=2; stage_fail "scope violation: outside the permitted folder (rc=7)" ;;
      *) CURRENT_STAGE=3; stage_fail "provisioning failed (rc=${rc})" ;;
    esac
  fi

  CURRENT_STAGE=1; stage_pass "connected to ${VCENTER}"
  CURRENT_STAGE=2; stage_pass "template ${TEMPLATE} located"

  TARGET_IP="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("ip") or "")' <<<"$result_json")"
  created_vm="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("vm_name") or "")' <<<"$result_json")"
  guest_os="$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("guest_os") or "")' <<<"$result_json")"

  [[ -n "$TARGET_IP" ]] || { CURRENT_STAGE=3; stage_fail "VM created but no IP was obtained"; }
  TARGET_HOST="$TARGET_IP"
  # From here on a failure must restore the template, so arm the EXIT trap.
  [[ "$MODE" == "convert" ]] && TEMPLATE_CONVERTED=1
  CURRENT_STAGE=3
  stage_pass "VM ${created_vm} at ${TARGET_IP} (${guest_os})"
fi

configure_ssh_auth

# ==============================================================================
# Stage 4 - place the scripts
# ==============================================================================
stage_begin 4 "PLACE THE SCRIPTS ON THE TARGET"
info "target: ${TARGET_SSH_USER}@${TARGET_HOST}"

# VMware Tools can report an IP before sshd finishes starting, so poll rather
# than judging on a single immediate attempt.
info "waiting up to ${SSH_WAIT}s for SSH on ${TARGET_HOST}"
ssh_ok=0
ssh_deadline=$((SECONDS + SSH_WAIT))
port_seen=0
while ((SECONDS < ssh_deadline)); do
  if ((! port_seen)) && timeout 5 bash -c "</dev/tcp/${TARGET_HOST}/22" 2>/dev/null; then
    port_seen=1
    info "port 22 is open"
  fi
  if rsh true 2>/dev/null; then
    ssh_ok=1
    break
  fi
  sleep 5
done

if ((! ssh_ok)); then
  diagnose_ssh "$TARGET_HOST"
  stage_fail "cannot SSH to ${TARGET_HOST} as ${TARGET_SSH_USER} after ${SSH_WAIT}s"
fi
info "SSH reachable"

remote_os="$(rsh '. /etc/os-release; printf "%s %s %s" "$ID" "${VERSION_ID%%.*}" "$(uname -m)"' 2>/dev/null || true)"
info "remote platform: ${remote_os}"

# Reuse this result rather than letting stage_bundle.sh probe again: its own
# probe uses plain ssh with BatchMode, which cannot authenticate by password.
read -r r_id r_major r_arch <<<"$remote_os"
if [[ -z "${r_major:-}" || -z "${r_arch:-}" ]]; then
  stage_fail "could not determine the remote platform (got '${remote_os}')"
fi

# --- remove superseded payloads baked into the template -----------------------
if ((PURGE_LEGACY)); then
  echo
  info "checking for legacy deployment folders"
  purged=0
  for legacy in "${LEGACY_PATHS[@]}"; do
    # The path is evaluated remotely so $HOME resolves to the target's user.
    if ! rsh "test -d ${legacy}" 2>/dev/null; then
      continue
    fi
    resolved="$(rsh "cd ${legacy} && pwd" 2>/dev/null || echo "$legacy")"
    count="$(rsh "find ${legacy} -type f 2>/dev/null | wc -l" 2>/dev/null || echo '?')"
    size="$(rsh "du -sh ${legacy} 2>/dev/null | cut -f1" 2>/dev/null || echo '?')"
    info "found ${resolved} (${count} files, ${size})"

    # Record what was there before removing it, so the log is auditable.
    rsh "ls -la ${legacy} 2>/dev/null | head -25" 2>/dev/null | sed 's/^/      /' || true

    if rsudo "rm -rf ${legacy}" 2>/dev/null; then
      if rsh "test -d ${legacy}" 2>/dev/null; then
        info "WARNING: ${resolved} still present after removal"
      else
        info "removed ${resolved}"
        purged=$((purged + 1))
      fi
    else
      info "WARNING: could not remove ${resolved}"
    fi
  done
  if ((purged == 0)); then
    info "no legacy folders present"
  else
    info "${purged} legacy folder(s) removed"
  fi
else
  info "--keep-legacy: leaving any existing 2026snowcommander folder in place"
fi
echo

info "building a bundle matched to this host"
bundle="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$bundle"' EXIT

info "building for el${r_major} ${r_arch}"
if ! "${BASE_DIR}/scripts/stage_bundle.sh" \
      --el "$r_major" --arch "$r_arch" --tar >"$bundle" 2>/tmp/e2e_stage.err; then
  sed 's/^/    /' /tmp/e2e_stage.err
  stage_fail "bundle staging failed - see the error above"
fi
info "bundle: $(du -h "$bundle" | cut -f1)"

rsh "rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}" 2>/dev/null \
  || stage_fail "cannot create ${REMOTE_DIR} on the target"
rsh "tar -C ${REMOTE_DIR} -xzf -" <"$bundle" \
  || stage_fail "failed to extract the bundle on the target"

placed="$(rsh "find ${REMOTE_DIR} -type f | wc -l" 2>/dev/null || echo 0)"
info "files placed: ${placed}"
rsh "ls -la ${REMOTE_DIR}" 2>/dev/null | sed 's/^/    /' || true

# Secrets go on their own channel into a 0600 file.
envfile="$(mktemp)"
chmod 600 "$envfile"
{
  printf 'FALCON_CID=%s\n' "${FALCON_CID:-}"
  # No provisioning token: this tenant does not require one.
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
  printf 'AZCM_TAGS=%s\n' "${AZCM_TAGS:-Environment=Test}"
  printf 'SYSLOG_SERVER1=%s\n' "${SYSLOG_SERVER1:-10.132.118.100}"
  printf 'SYSLOG_SERVER2=%s\n' "${SYSLOG_SERVER2:-10.50.118.100}"
  printf 'SYSLOG_PORT=%s\n' "${SYSLOG_PORT:-514}"
  [[ -n "${RHSM_USERNAME:-}" ]] && printf 'RHSM_USERNAME=%s\n' "$RHSM_USERNAME"
  [[ -n "${RHSM_PASSWORD:-}" ]] && printf 'RHSM_PASSWORD=%s\n' "$RHSM_PASSWORD"
} >"$envfile"
rsh "umask 077; cat > ${REMOTE_DIR}/securitytools.env" <"$envfile"
shred -u "$envfile" 2>/dev/null || rm -f "$envfile"
info "securitytools.env written with mode 600"

# --- FQDN entry in /etc/hosts -------------------------------------------------
# The clone inherits the template's hostname and IP because no guest
# customization is applied. This makes <hostname>.<domain> resolve locally
# without renaming the host.
if [[ -n "$FQDN_DOMAIN" ]]; then
  echo
  info "configuring ${FQDN_DOMAIN} FQDN in /etc/hosts"
  host_short="$(rsh 'hostname -s' 2>/dev/null || true)"
  host_ip="$(rsh "ip -4 route get 1.1.1.1 2>/dev/null | awk '{print \$7; exit}'" 2>/dev/null || true)"
  [[ -n "$host_ip" ]] || host_ip="$TARGET_HOST"

  if [[ -z "$host_short" ]]; then
    info "WARNING: could not read the hostname; skipping /etc/hosts"
  else
    host_fqdn="${host_short}.${FQDN_DOMAIN}"
    info "hostname=${host_short}  ip=${host_ip}  fqdn=${host_fqdn}"

    # Back up, drop any stale line for this host, append the canonical entry.
    rsudo "cp -a /etc/hosts /etc/hosts.sectools-bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    rsudo "sh -c \"grep -vE '(^|[[:space:]])${host_short}([[:space:]]|\\\$)' /etc/hosts > /tmp/.hosts.new; \
                   printf '%s\\t%s %s\\n' '${host_ip}' '${host_fqdn}' '${host_short}' >> /tmp/.hosts.new; \
                   install -o root -g root -m 644 /tmp/.hosts.new /etc/hosts; rm -f /tmp/.hosts.new\"" \
      2>/dev/null || info "WARNING: could not update /etc/hosts"

    echo "    --- /etc/hosts ---"
    rsh 'cat /etc/hosts' 2>/dev/null | sed 's/^/      /' || true
    resolved="$(rsh 'hostname -f' 2>/dev/null || true)"
    info "hostname -f now reports: ${resolved:-unknown}"
  fi
  echo
fi

stage_pass "${placed} files placed in ${REMOTE_DIR}"

# ==============================================================================
# Stage 5 - install
# ==============================================================================
stage_begin 5 "INSTALL THE SECURITY TOOLS"

# --- Red Hat subscription -----------------------------------------------------
# rsyslog is installed from Red Hat repositories, so an unregistered RHEL host
# cannot complete the syslog component. Register first, and for appliance
# templates give the entitlement back afterwards.
resolve_rhsm_mode() {
  if [[ "$RHSM_MODE" != "auto" ]]; then
    printf '%s' "$RHSM_MODE"
    return
  fi
  # Red Hat base templates keep their subscription; GI/Vocera appliances do not.
  local hint="${TEMPLATE:-$EXISTING_HOST}"
  shopt -s nocasematch
  if [[ "$hint" == *redhat* ]]; then
    printf 'keep'
  elif [[ "$hint" == *gi* || "$hint" == *engage* || "$hint" == *vocera* ]]; then
    printf 'remove'
  else
    printf 'skip'
  fi
  shopt -u nocasematch
}

RHSM_EFFECTIVE="$(resolve_rhsm_mode)"
info "RHSM mode: ${RHSM_MODE} -> effective '${RHSM_EFFECTIVE}'"

if [[ "$RHSM_EFFECTIVE" != "skip" ]]; then
  if [[ -z "${RHSM_USERNAME:-}" || -z "${RHSM_PASSWORD:-}" ]]; then
    info "WARNING: RHSM_USERNAME/RHSM_PASSWORD unset; skipping registration"
    info "         the syslog component may fail without Red Hat repositories"
  else
    info "registering with Red Hat (repositories are chosen per RHEL version)"
    if rsudo "RHSM_USERNAME='${RHSM_USERNAME}' RHSM_PASSWORD='${RHSM_PASSWORD}' ${REMOTE_DIR}/sub-reg.sh register" 2>&1 \
        | sed 's/^/    /'; then
      RHSM_APPLIED=1
      info "subscription active"
    else
      info "WARNING: registration failed; continuing (syslog may fail)"
    fi
  fi
fi

echo
info "running: sudo ${REMOTE_DIR}/security.sh ${COMPONENTS}"
echo

install_rc=0
rsudo "${REMOTE_DIR}/security.sh ${COMPONENTS}" 2>&1 | sed 's/^/    /' || install_rc=$?

echo
case "$install_rc" in
  0) stage_pass "every requested component installed" ;;
  10) STAGE_RESULT[5]=PARTIAL; STAGE_DETAIL[5]="some components failed"
      printf '%s[%s]   STAGE 5 PARTIAL%s - some components failed\n' "$C_YELLOW" "$(ts)" "$C_RESET" ;;
  *) stage_fail "install exited ${install_rc}" ;;
esac

# ==============================================================================
# Stage 6 - verify with systemctl
# ==============================================================================
stage_begin 6 "VERIFY SERVICE STATUS WITH SYSTEMCTL"

echo "    --- systemctl is-active ---"
for svc in falcon-sensor taniumclient rsyslog; do
  state="$(rsh "systemctl is-active ${svc} 2>/dev/null || echo not-found" 2>/dev/null || echo unknown)"
  printf '    %-22s %s\n' "$svc" "$state"
done

echo
echo "    --- installed packages ---"
rsh "rpm -q falcon-sensor TaniumClient rsyslog 2>&1 || true" 2>/dev/null | sed 's/^/    /'

echo
echo "    --- Tanium ---"
rsh "rpm -q TaniumClient 2>&1; systemctl is-enabled taniumclient 2>/dev/null || true" 2>/dev/null | sed 's/^/    /'

echo
echo "    --- CrowdStrike CID and agent ID ---"
# The CID is an identifier, not a credential, so it is safe to display.
rsudo "/opt/CrowdStrike/falconctl -g --cid --aid 2>&1 || true" 2>/dev/null | sed 's/^/    /'

echo
echo "    --- Azure Arc connection state ---"
rsh "command -v azcmagent >/dev/null 2>&1 && (azcmagent show 2>&1 | head -12) || echo 'azcmagent not installed'" \
  2>/dev/null | sed 's/^/    /'

echo
echo "    --- CMDB sync account ---"
rsh "id cmdbsync 2>&1 || echo 'cmdbsync user absent'" 2>/dev/null | sed 's/^/    /'
rsudo "visudo -cf /etc/sudoers.d/cmdbsync 2>&1 || echo 'sudoers policy missing or invalid'" \
  2>/dev/null | sed 's/^/    /'

echo
echo "    --- Red Hat subscription ---"
rsudo "subscription-manager identity 2>&1 | head -4 || true" 2>/dev/null | sed 's/^/    /'

echo
echo "    --- structured verification ---"
verify_rc=0
rsudo "${REMOTE_DIR}/security.sh verify" 2>&1 | sed 's/^/    /' || verify_rc=$?

active_count="$(rsh 'c=0; for s in falcon-sensor taniumclient rsyslog; do systemctl is-active --quiet $s 2>/dev/null && c=$((c+1)); done; echo $c' 2>/dev/null || echo 0)"
echo
if [[ "$active_count" -gt 0 ]]; then
  stage_pass "${active_count} security service(s) active"
else
  stage_fail "no security services are active after installation"
fi

# Verification has happened, so an appliance template can hand its entitlement
# back now. Red Hat templates intentionally stay registered.
if [[ "$RHSM_EFFECTIVE" == "remove" && "$RHSM_APPLIED" == "1" ]]; then
  echo
  info "appliance template: unregistering from Red Hat now that verification is done"
  rsudo "${REMOTE_DIR}/sub-reg.sh unregister" 2>&1 | sed 's/^/    /' \
    || info "WARNING: unregister reported a problem - check manually"
  rsudo "${REMOTE_DIR}/sub-reg.sh status" 2>&1 | sed 's/^/    /' || true
elif [[ "$RHSM_EFFECTIVE" == "keep" && "$RHSM_APPLIED" == "1" ]]; then
  echo
  info "Red Hat template: leaving the subscription registered by design"
fi

# ==============================================================================
# Stage 7 - uninstall
# ==============================================================================
stage_begin 7 "UNINSTALL THE TOOLS"
if ((KEEP_TOOLS)); then
  stage_skip "--keep-tools was supplied"
else
  info "removing: ${UNINSTALL_COMPONENTS}"
  info "retaining: cmdbsync account and Red Hat subscription"
  echo
  uninstall_rc=0
  rsudo "${REMOTE_DIR}/uninstall.sh ${UNINSTALL_COMPONENTS}" 2>&1 | sed 's/^/    /' || uninstall_rc=$?
  echo

  echo "    --- post-uninstall systemctl ---"
  for svc in falcon-sensor taniumclient; do
    state="$(rsh "systemctl is-active ${svc} 2>/dev/null || echo not-found" 2>/dev/null || echo unknown)"
    printf '    %-22s %s\n' "$svc" "$state"
  done

  echo
  echo "    --- agent packages remaining ---"
  remaining="$(rsh 'rpm -q falcon-sensor TaniumClient 2>&1 | grep -c "is not installed" || echo 0' 2>/dev/null || echo 0)"
  rsh "rpm -q falcon-sensor TaniumClient 2>&1 || true" 2>/dev/null | sed 's/^/    /'

  echo
  echo "    --- azcmagent removed? ---"
  rsh "command -v azcmagent >/dev/null 2>&1 && echo 'still present' || echo 'removed'" \
    2>/dev/null | sed 's/^/    /'

  # The point of a partial teardown is that these two SURVIVE. Prove it
  # rather than assuming uninstall.sh respected the component list.
  echo
  echo "    --- RETAINED: cmdbsync account ---"
  retained_cmdb=0
  if rsh 'id cmdbsync' 2>/dev/null | sed 's/^/    /'; then
    retained_cmdb=1
  else
    printf '    %sMISSING - cmdbsync was removed unexpectedly%s\n' "$C_RED" "$C_RESET"
  fi

  echo
  echo "    --- RETAINED: Red Hat subscription ---"
  retained_sub=0
  if rsudo 'subscription-manager identity 2>&1 | head -3' 2>/dev/null | sed 's/^/    /'; then
    rsudo 'subscription-manager identity >/dev/null 2>&1' 2>/dev/null && retained_sub=1
  fi
  ((retained_sub)) || printf '    %sNOT REGISTERED - subscription was lost%s\n' "$C_YELLOW" "$C_RESET"

  echo
  if [[ "$remaining" == "2" ]] && ((retained_cmdb)); then
    stage_pass "agents removed; cmdbsync and subscription retained"
  elif [[ "$remaining" != "2" ]]; then
    STAGE_RESULT[7]=PARTIAL
    STAGE_DETAIL[7]="some agent packages still present"
    printf '%s[%s]   STAGE 7 PARTIAL%s - some agent packages still present\n' "$C_YELLOW" "$(ts)" "$C_RESET"
  else
    STAGE_RESULT[7]=PARTIAL
    STAGE_DETAIL[7]="agents removed but cmdbsync did not survive"
    printf '%s[%s]   STAGE 7 PARTIAL%s - cmdbsync should have been retained\n' "$C_YELLOW" "$(ts)" "$C_RESET"
  fi
fi

# ==============================================================================
# Stage 8 - confirm the scripts survived
# ==============================================================================
stage_begin 8 "CONFIRM THE SCRIPTS REMAIN IN ${REMOTE_DIR}"

echo "    --- directory listing ---"
rsh "ls -la ${REMOTE_DIR} 2>/dev/null" 2>/dev/null | sed 's/^/    /' || true

echo
missing=0
for f in security.sh lib/pkg_select.sh sentinel_core.sh uninstall.sh; do
  if rsh "test -f ${REMOTE_DIR}/${f}" 2>/dev/null; then
    printf '    %-28s present\n' "$f"
  else
    printf '    %-28s %sMISSING%s\n' "$f" "$C_RED" "$C_RESET"
    missing=$((missing + 1))
  fi
done

# The secrets file must not be left behind on a decommissioned test VM.
if rsh "test -f ${REMOTE_DIR}/securitytools.env" 2>/dev/null; then
  info "removing securitytools.env from the target"
  rsh "shred -u ${REMOTE_DIR}/securitytools.env 2>/dev/null || rm -f ${REMOTE_DIR}/securitytools.env" || true
fi

final_count="$(rsh "find ${REMOTE_DIR} -type f | wc -l" 2>/dev/null || echo 0)"
echo
if ((missing == 0)); then
  stage_pass "all scripts present (${final_count} files) and secrets removed"
else
  stage_fail "${missing} expected script(s) missing from ${REMOTE_DIR}"
fi

# ==============================================================================
# Optional finalisation - turn the validated, cleaned VM back into a template
# ==============================================================================
if ((CONVERT_TO_TEMPLATE)); then
  printf '\n%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"
  printf '%s FINALISE - CONVERT THE VM BACK INTO A TEMPLATE%s\n' "$C_BOLD" "$C_RESET"
  printf '%s==============================================================================%s\n' "$C_CYAN" "$C_RESET"

  if [[ -n "$EXISTING_HOST" ]]; then
    info "skipped: --existing-host was used, so no VM was created here"
  elif [[ -z "${created_vm:-}" ]]; then
    info "skipped: no VM name recorded"
  else
    info "shutting down and converting '${created_vm}' to a template"
    finalize_args=(--vcenter "$VCENTER" --finalize "$created_vm")
    [[ -n "$INSECURE" ]] && finalize_args+=("$INSECURE")

    if python3 "${BASE_DIR}/scripts/vsphere_provision.py" "${finalize_args[@]}"; then
      FINALIZED=1
      printf '%s[%s]   FINALISE PASS%s - %s is now a template\n' \
        "$C_GREEN" "$(ts)" "$C_RESET" "$created_vm"
    else
      printf '%s[%s]   FINALISE FAIL%s - conversion failed; the VM is left in place\n' \
        "$C_RED" "$(ts)" "$C_RESET"
    fi
  fi
fi

summary

failed=0
for i in 1 2 3 4 5 6 7 8; do
  [[ "${STAGE_RESULT[$i]:-}" == "FAIL" ]] && failed=$((failed + 1))
done
((failed == 0)) || exit 39
exit 0
