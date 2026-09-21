#!/usr/bin/env bash
# ==============================================================================
# target.sh — single entry point for vSphere templates and fleet targets
#
# Defines the SnowCommander template inventory (FW, BLR, STC) and wraps every
# execution path: vSphere validation, fleet deploy over SSH, container, and
# GitHub Actions.
#
# Credentials live in ~/.snowcommander-creds.env (see credentials.env.example).
# Nothing secret is passed on the command line.
#
# Usage:
#   ./target.sh list
#   ./target.sh list-vcenter fw
#   ./target.sh e2e fw FW-Redhat-9
#   ./target.sh e2e-site blr --template-cycle
#   ./target.sh e2e-all-sites --template-cycle
#   ./target.sh existing blr-gi-6
#   ./target.sh write-inventory ./inventory
#   ./target.sh plan
#   ./target.sh deploy
#   ./target.sh container plan
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${CREDS_FILE:-${HOME}/.snowcommander-creds.env}"
INVENTORY="${INVENTORY:-${BASE_DIR}/inventory}"
IMAGE="${SECTOOLS_IMAGE:-sectools-deployer:latest}"

# ------------------------------------------------------------------------------
# Site catalogue — matches SnowCommander/Templates in each vCenter.
# Override portgroups with BLR_PORTGROUP, FW_PORTGROUP, STC_PORTGROUP.
# ------------------------------------------------------------------------------
declare -A SITE_VCENTER=(
  [blr]=blr-vsphere-01.strykercorp.com
  [fw]=fw-vsphere-01.strykercorp.com
  [stc]=stc-vsphere-01.strykercorp.com
)

declare -A SITE_PORTGROUP=(
  [blr]="${BLR_PORTGROUP:-VM Network}"
  [fw]="${FW_PORTGROUP:-fwa-vlan106}"
  [stc]="${STC_PORTGROUP:-VM Network}"
)

declare -A SITE_FQDN=(
  [blr]=""
  [fw]="${FW_FQDN_DOMAIN:-vcraeng.com}"
  [stc]=""
)

# Templates visible under SnowCommander/Template(s) (from vCenter inventory).
SITE_TEMPLATES_blr=(
  BLR-Redhat-9 BLR-Redhat-10
  BLR-GI-6.6 BLR-GI-7.1 BLR-GI-7.2 BLR-GI-7.3
)
SITE_TEMPLATES_fw=(
  FW-Redhat-9 FW-Redhat-10
  FW-GI-6.6 FW-GI-7.1 FW-GI-7.2 FW-GI-7.3
)
SITE_TEMPLATES_stc=(
  STC-Redhat-9 STC-Redhat-10
  STC-GI-6.6 STC-GI-7.1 STC-GI-7.2 STC-GI-7.3
)

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 2; }

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Commands:
  list                         show sites, vCenters, portgroups, templates
  list-vcenter <site>          query vCenter for templates in SnowCommander scope
  list-folders <site>          list folders under SnowCommander (diagnostics)

  e2e <site> <template>        validate one template (clone mode by default)
  e2e-site <site>              validate every template on one vCenter
  e2e-all-sites                validate all sites (background jobs, one log each)
  existing <hostname>          run stages 4-8 on a host that already exists

  write-inventory [path]       create/update a fleet inventory file (hostnames only)

  plan | verify | deploy       fleet fan-out via deploy_targets.sh (needs inventory)
  container plan|verify|deploy run the same through the sectools-deployer image

  help                         this message

Common options (append after the command):
  --template-cycle             round-trip on the template itself (no extra VM)
  --clone                      create a new VM instead of converting the template
  --keep-tools                 skip uninstall stage
  --portgroup 'NAME'           override the site default portgroup
  --parallel N                 fleet concurrency (default 5)
  --components LIST            e.g. "crowdstrike tanium" or "all"
  --insecure                   skip vCenter TLS verification

Examples:
  set -a; source ~/.snowcommander-creds.env; set +a
  ./target.sh list
  ./target.sh e2e fw FW-Redhat-9 --template-cycle --insecure
  ./target.sh e2e-site blr --template-cycle --insecure
  ./target.sh write-inventory && ./target.sh plan
  ./target.sh container deploy
EOF
}

load_creds() {
  [[ -r "$CREDS_FILE" ]] || die "credentials not found: ${CREDS_FILE} (cp credentials.env.example ${CREDS_FILE})"
  # shellcheck disable=SC1090
  set -a; source "$CREDS_FILE"; set +a
}

resolve_site() {
  local site="${1,,}"
  [[ -n "${SITE_VCENTER[$site]:-}" ]] || die "unknown site '${1}'. Known: blr, fw, stc"
  printf '%s' "$site"
}

site_templates() {
  local site="$1"
  local -n _out=$2
  case "$site" in
    blr) _out=("${SITE_TEMPLATES_blr[@]}") ;;
    fw)  _out=("${SITE_TEMPLATES_fw[@]}") ;;
    stc) _out=("${SITE_TEMPLATES_stc[@]}") ;;
    *) die "unknown site: $site" ;;
  esac
}

# Parse trailing options shared by e2e commands.
E2E_EXTRA=()
E2E_TEMPLATE_CYCLE=0
E2E_INSECURE=1
FLEET_PARALLEL="${PARALLEL:-5}"
FLEET_COMPONENTS="${COMPONENTS:-all}"

parse_common_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template-cycle) E2E_TEMPLATE_CYCLE=1; shift ;;
      --clone) E2E_TEMPLATE_CYCLE=0; shift ;;
      --keep-tools) E2E_EXTRA+=(--keep-tools); shift ;;
      --portgroup) E2E_EXTRA+=(--portgroup "$2"); shift 2 ;;
      --parallel) FLEET_PARALLEL="$2"; shift 2 ;;
      --components) FLEET_COMPONENTS="$2"; shift 2 ;;
      --insecure) E2E_INSECURE=1; shift ;;
      --fqdn-domain) E2E_EXTRA+=(--fqdn-domain "$2"); shift 2 ;;
      --rhsm-mode) E2E_EXTRA+=(--rhsm-mode "$2"); shift 2 ;;
      --env-disposition) E2E_EXTRA+=(--env-disposition "$2"); shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

run_e2e() {
  local site="$1" template="$2"

  local vcenter="${SITE_VCENTER[$site]}"
  local portgroup="${SITE_PORTGROUP[$site]}"
  local fqdn="${SITE_FQDN[$site]}"
  local -a args=(
    "${BASE_DIR}/scripts/e2e_validate.sh"
    --vcenter "$vcenter"
    --template "$template"
  )

  if (( E2E_TEMPLATE_CYCLE )); then
    args+=(--template-cycle)
  else
    args+=(--name "e2e-${site}-${template,,}-$(date +%Y%m%d%H%M%S)")
  fi

  # Only pass --portgroup when the caller did not override it.
  local has_pg=0
  for a in "${E2E_EXTRA[@]}"; do [[ "$a" == --portgroup ]] && has_pg=1; done
  (( has_pg )) || args+=(--portgroup "$portgroup")

  [[ -n "$fqdn" ]] && args+=(--fqdn-domain "$fqdn")
  (( E2E_INSECURE )) && args+=(--insecure)

  log "e2e: site=${site} vcenter=${vcenter} template=${template}"
  "${args[@]}" "${E2E_EXTRA[@]}"
}

cmd_list() {
  local site
  for site in blr fw stc; do
    local -a templates=()
    site_templates "$site" templates
    printf '%s\n' "=== ${site} ==="
    printf '  vCenter:   %s\n' "${SITE_VCENTER[$site]}"
    printf '  portgroup: %s\n' "${SITE_PORTGROUP[$site]}"
    [[ -n "${SITE_FQDN[$site]}" ]] && printf '  fqdn:      %s\n' "${SITE_FQDN[$site]}"
    printf '  templates: %s\n' "$(IFS=' '; echo "${templates[*]}")"
    echo
  done
  printf 'Fleet inventory file: %s\n' "$INVENTORY"
  printf 'Credentials file:     %s\n' "$CREDS_FILE"
}

cmd_list_vcenter() {
  local site
  site="$(resolve_site "${1:?usage: list-vcenter <blr|fw|stc>}")"
  load_creds
  local -a args=(--vcenter "${SITE_VCENTER[$site]}" --list-templates)
  (( E2E_INSECURE )) && args+=(--insecure)
  exec python3 "${BASE_DIR}/scripts/vsphere_provision.py" "${args[@]}"
}

cmd_list_folders() {
  local site
  site="$(resolve_site "${1:?usage: list-folders <blr|fw|stc>}")"
  load_creds
  exec python3 "${BASE_DIR}/scripts/vsphere_provision.py" \
    --vcenter "${SITE_VCENTER[$site]}" --list-folders --insecure
}

cmd_e2e_site() {
  local site
  site="$(resolve_site "${1:?usage: e2e-site <blr|fw|stc>}")"
  shift
  parse_common_opts "$@"

  local -a templates=()
  site_templates "$site" templates
  (( E2E_INSECURE )) || E2E_EXTRA+=(--insecure)
  local t rc=0
  for t in "${templates[@]}"; do
    log "========== ${site} / ${t} =========="
    if run_e2e "$site" "$t" 2>&1 | tee "/tmp/e2e-${site}-${t}.log"; then
      :
    else
      rc=$?
    fi
  done
  exit "$rc"
}

cmd_e2e_all_sites() {
  parse_common_opts "$@"
  load_creds
  mkdir -p /tmp/e2e-runs
  : > /tmp/e2e-runs/summary.txt

  run_one_site() {
    local site="$1"
    local -a templates=()
    site_templates "$site" templates
    local t
    for t in "${templates[@]}"; do
      local log="/tmp/e2e-runs/${site}-${t}.log"
      if (( E2E_TEMPLATE_CYCLE )); then
        "${BASE_DIR}/scripts/e2e_validate.sh" \
          --vcenter "${SITE_VCENTER[$site]}" \
          --template "$t" \
          --template-cycle \
          --portgroup "${SITE_PORTGROUP[$site]}" \
          ${SITE_FQDN[$site]:+--fqdn-domain "${SITE_FQDN[$site]}"} \
          --insecure \
          "${E2E_EXTRA[@]}" \
          >"$log" 2>&1 || true
      else
        "${BASE_DIR}/scripts/e2e_validate.sh" \
          --vcenter "${SITE_VCENTER[$site]}" \
          --template "$t" \
          --name "e2e-${site}-${t,,}-$(date +%Y%m%d%H%M%S)" \
          --portgroup "${SITE_PORTGROUP[$site]}" \
          --insecure \
          "${E2E_EXTRA[@]}" \
          >"$log" 2>&1 || true
      fi
      local ec=$?
      printf '%s\t%s\texit=%s\n' "$site" "$t" "$ec" >> /tmp/e2e-runs/summary.txt
    done
  }

  run_one_site blr &
  run_one_site fw &
  run_one_site stc &
  wait

  log "combined summary:"
  column -t /tmp/e2e-runs/summary.txt 2>/dev/null || cat /tmp/e2e-runs/summary.txt
}

cmd_existing() {
  local host="${1:?usage: existing <hostname>}"
  shift
  parse_common_opts "$@"
  load_creds
  exec "${BASE_DIR}/scripts/e2e_validate.sh" --existing-host "$host" "${E2E_EXTRA[@]}"
}

cmd_write_inventory() {
  local out="${1:-$INVENTORY}"
  {
    echo "# Fleet inventory — one hostname or IP per line."
    echo "# Generated by target.sh on $(date -Iseconds)"
    echo "# Uncomment hosts as they come online; blank lines and # comments are ignored."
    echo
    echo "# --- BLR templates (replace with running VM hostnames when known) ---"
    for t in "${SITE_TEMPLATES_blr[@]}"; do echo "# ${t}"; done
    echo
    echo "# --- FW templates ---"
    for t in "${SITE_TEMPLATES_fw[@]}"; do echo "# ${t}"; done
    echo
    echo "# --- STC templates (confirm names with: ./target.sh list-vcenter stc) ---"
    for t in "${SITE_TEMPLATES_stc[@]}"; do echo "# ${t}"; done
    echo
    echo "# Example live targets:"
    echo "# rhel9-np-01.strykercorp.com"
    echo "# 10.50.12.45"
  } >"$out"
  chmod 600 "$out"
  log "wrote ${out} — edit it, uncomment/add real hostnames, then run: ./target.sh plan"
}

fleet_mode() {
  local mode="$1"
  [[ -r "$INVENTORY" ]] || die "inventory not found: ${INVENTORY} (run: ./target.sh write-inventory)"
  load_creds
  exec "${BASE_DIR}/scripts/deploy_targets.sh" \
    --inventory "$INVENTORY" \
    --mode "$mode" \
    --components "$FLEET_COMPONENTS" \
    --parallel "$FLEET_PARALLEL" \
    --retries "${RETRIES:-1}"
}

container_run() {
  local mode="${1:-plan}"
  [[ -r "$INVENTORY" ]] || die "inventory not found: ${INVENTORY}"
  local cmd="$mode"
  [[ "$mode" == deploy ]] && cmd="deploy ${FLEET_COMPONENTS}"

  if command -v podman >/dev/null 2>&1; then
    RUNNER=podman
  elif command -v docker >/dev/null 2>&1; then
    RUNNER=docker
  else
    die "neither podman nor docker found"
  fi

  load_creds
  exec "$RUNNER" run --rm \
    --env-file "$CREDS_FILE" \
    -v "${SSH_KEY_FILE:-${HOME}/.ssh/id_ed25519}:/run/secrets/ssh_key:ro" \
    -v "${INVENTORY}:/etc/snowcommander/inventory:ro" \
    -e INVENTORY=/etc/snowcommander/inventory \
    -e PARALLEL="$FLEET_PARALLEL" \
    -e RETRIES="${RETRIES:-1}" \
    "$IMAGE" \
    $cmd
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help | -h | --help) usage ;;
    list) cmd_list ;;
    list-vcenter) cmd_list_vcenter "$@" ;;
    list-folders) cmd_list_folders "$@" ;;
    e2e)
      site="$(resolve_site "${1:?usage: e2e <site> <template>}")"
      template="${2:?usage: e2e <site> <template>}"
      shift 2
      load_creds
      parse_common_opts "$@"
      (( E2E_INSECURE )) || E2E_EXTRA+=(--insecure)
      run_e2e "$site" "$template"
      ;;
    e2e-site) load_creds; cmd_e2e_site "$@" ;;
    e2e-all-sites) cmd_e2e_all_sites "$@" ;;
    existing) cmd_existing "$@" ;;
    write-inventory) cmd_write_inventory "${1:-}" ;;
    plan) parse_common_opts "$@"; fleet_mode plan ;;
    verify) parse_common_opts "$@"; fleet_mode verify ;;
    deploy) parse_common_opts "$@"; fleet_mode deploy ;;
    container)
      sub="${1:?usage: container plan|verify|deploy}"
      shift
      parse_common_opts "$@"
      container_run "$sub"
      ;;
    *)
      die "unknown command: ${cmd} (try: ./target.sh help)"
      ;;
  esac
}

main "$@"
