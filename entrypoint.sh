#!/usr/bin/env bash
# ==============================================================================
# entrypoint.sh — container entry point
#
# The container is a CONTROL PLANE. It never installs a security agent into
# itself: Falcon is a kernel/eBPF sensor bound to the host kernel, Tanium needs
# host systemd and hardware inventory, and azcmagent registers the host identity
# in Azure. An agent running in this container would report the container, not
# the VM. Everything is therefore deployed outward over SSH.
#
# Commands:
#   deploy [components]   install on every target (default: all)
#   plan                  detect platform and validate packages, change nothing
#   verify                report current state on every target
#   packages              show the staged package matrix and digest state
#   bundle <el> <arch>    list what a target of that shape would receive
#   shell                 interactive shell for troubleshooting
#
# Targets come from TARGETS (comma-separated) or INVENTORY (path to a file).
# Secrets come from the environment or a mounted env file; nothing is baked in.
# ==============================================================================

set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/snowcommander}"
cd "$APP_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { err "$*"; exit 2; }

# ------------------------------------------------------------------------------
# Optional env file mounted as a Docker/Podman secret.
# Environment variables already set take precedence over the file.
# ------------------------------------------------------------------------------
load_env_file() {
  local f="${SECURITYTOOLS_ENV_FILE:-/run/secrets/securitytools.env}"
  [[ -r "$f" ]] || return 0
  log "loading configuration from ${f}"
  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    # Do not clobber an explicitly provided environment variable.
    [[ -n "${!key:-}" ]] && continue
    export "${key}=${value}"
  done <"$f"
}

# ------------------------------------------------------------------------------
# SSH key: accept a mounted secret and normalise permissions, because a
# bind-mounted key often arrives with group/world bits that ssh rejects.
# ------------------------------------------------------------------------------
prepare_ssh() {
  install -d -m 700 "${HOME}/.ssh"

  local src="${SSH_KEY_FILE:-/run/secrets/ssh_key}"
  if [[ -r "$src" ]]; then
    install -m 600 "$src" "${HOME}/.ssh/id_deploy"
    export SSH_KEY="${HOME}/.ssh/id_deploy"
    log "deployment key installed from ${src}"
  elif [[ -n "${SSH_KEY:-}" && -r "${SSH_KEY}" ]]; then
    install -m 600 "$SSH_KEY" "${HOME}/.ssh/id_deploy"
    export SSH_KEY="${HOME}/.ssh/id_deploy"
    log "deployment key installed from ${SSH_KEY}"
  else
    log "NOTE: no SSH key mounted; relying on an agent or on ssh defaults"
  fi

  local kh="${SSH_KNOWN_HOSTS_FILE:-/run/secrets/known_hosts}"
  if [[ -r "$kh" ]]; then
    install -m 644 "$kh" "${HOME}/.ssh/known_hosts"
    log "host key verification enabled from ${kh}"
  fi
}

# ------------------------------------------------------------------------------
# Resolve targets into arguments for deploy_targets.sh.
# ------------------------------------------------------------------------------
target_args() {
  if [[ -n "${INVENTORY:-}" ]]; then
    [[ -r "$INVENTORY" ]] || die "INVENTORY is not readable inside the container: ${INVENTORY}"
    printf '%s\n%s\n' --inventory "$INVENTORY"
  elif [[ -n "${TARGETS:-}" ]]; then
    printf '%s\n%s\n' --hosts "$TARGETS"
  else
    die "set TARGETS=host1,host2 or INVENTORY=/path/to/file"
  fi
}

common_args() {
  printf '%s\n%s\n' --user "${SSH_USER:-tpx-admin}"
  printf '%s\n%s\n' --port "${SSH_PORT:-22}"
  printf '%s\n%s\n' --parallel "${PARALLEL:-5}"
  printf '%s\n%s\n' --retries "${RETRIES:-1}"
  [[ -n "${SSH_KEY:-}" ]] && printf '%s\n%s\n' --key "$SSH_KEY"
  return 0
}

run_orchestrator() {
  local mode="$1" components="${2:-all}"
  local -a args=()
  mapfile -t -O "${#args[@]}" args < <(target_args)
  mapfile -t -O "${#args[@]}" args < <(common_args)
  args+=(--mode "$mode" --components "$components")
  exec ./scripts/deploy_targets.sh "${args[@]}"
}

# ------------------------------------------------------------------------------
main() {
  local cmd="${1:-deploy}"
  shift || true

  load_env_file

  case "$cmd" in
    deploy)
      prepare_ssh
      run_orchestrator deploy "${1:-${COMPONENTS:-all}}"
      ;;
    plan)
      prepare_ssh
      run_orchestrator plan all
      ;;
    verify)
      prepare_ssh
      run_orchestrator verify all
      ;;
    packages)
      exec ./lib/pkg_select.sh matrix
      ;;
    bundle)
      local el="${1:?usage: bundle <el-version> <arch>}"
      local arch="${2:?usage: bundle <el-version> <arch>}"
      exec ./scripts/stage_bundle.sh --el "$el" --arch "$arch" --list
      ;;
    healthcheck)
      # Image is usable if the orchestrator and at least one package are present.
      [[ -x ./scripts/deploy_targets.sh ]] || exit 1
      compgen -G 'crowdstrike/*.rpm' >/dev/null || exit 1
      compgen -G 'tanium/*.rpm' >/dev/null || exit 1
      echo ok
      ;;
    shell | bash)
      exec /bin/bash "$@"
      ;;
    -h | --help | help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      die "unknown command: ${cmd} (deploy|plan|verify|packages|bundle|healthcheck|shell)"
      ;;
  esac
}

main "$@"
