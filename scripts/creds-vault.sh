#!/usr/bin/env bash
# ==============================================================================
# creds-vault.sh — encrypt ~/.snowcommander-creds.env with ansible-vault
#
#   ./scripts/creds-vault.sh init       # create ~/.snowcommander-vault.pass
#   ./scripts/creds-vault.sh encrypt    # plain .env -> .env.vault, backup plain
#   ./scripts/creds-vault.sh edit       # edit decrypted creds in $EDITOR
#   ./scripts/creds-vault.sh view       # print decrypted creds (careful)
#   ./scripts/creds-vault.sh decrypt    # .env.vault -> plain .env
#   ./scripts/creds-vault.sh status     # show which creds files exist
#
# Reuse an existing vault password file (e.g. ansible):
#   export SNOWCOMMANDER_VAULT_PASS_FILE=/path/to/vault_password_file
#
# target.sh loads plain .env automatically; if only .env.vault exists it decrypts
# to a temp file in memory for the current process only.
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

CREDS_PLAIN="${CREDS_FILE:-${HOME}/.snowcommander-creds.env}"
CREDS_VAULT="${CREDS_VAULT:-${CREDS_PLAIN}.vault}"
VAULT_PASS="${SNOWCOMMANDER_VAULT_PASS_FILE:-${HOME}/.snowcommander-vault.pass}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
info() { printf '[creds-vault] %s\n' "$*"; }

need_vault_pass() {
  [[ -r "$VAULT_PASS" ]] || die "vault password file missing: ${VAULT_PASS} (run: $0 init)"
}

need_ansible_vault() {
  command -v ansible-vault >/dev/null 2>&1 \
    || die "ansible-vault not found (install ansible-core)"
}

cmd_init() {
  if [[ -r "$VAULT_PASS" ]]; then
    info "vault password file already exists: ${VAULT_PASS}"
    return 0
  fi
  umask 077
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 >"$VAULT_PASS"
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 >"$VAULT_PASS"
  fi
  chmod 600 "$VAULT_PASS"
  info "created ${VAULT_PASS} (mode 600)"
  info "back this file up securely; without it you cannot decrypt creds"
}

cmd_encrypt() {
  need_ansible_vault
  need_vault_pass
  [[ -r "$CREDS_PLAIN" ]] || die "plain creds not found: ${CREDS_PLAIN}"
  if grep -q '^\$ANSIBLE_VAULT;' "$CREDS_PLAIN" 2>/dev/null; then
    die "${CREDS_PLAIN} is already ansible-vault encrypted; use edit or decrypt first"
  fi
  ansible-vault encrypt "$CREDS_PLAIN" \
    --vault-password-file "$VAULT_PASS" \
    --encrypt-vault-id default \
    --output "$CREDS_VAULT"
  chmod 600 "$CREDS_VAULT"
  local backup="${CREDS_PLAIN}.plain.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$CREDS_PLAIN" "$backup"
  chmod 600 "$backup"
  shred -u "$CREDS_PLAIN" 2>/dev/null || rm -f "$CREDS_PLAIN"
  info "encrypted -> ${CREDS_VAULT}"
  info "plain backup -> ${backup} (shred when confirmed working)"
  info "load creds: set -a; source <(./scripts/creds-vault.sh materialize); set +a"
  info "or run target.sh / e2e — load_creds decrypts automatically"
}

cmd_edit() {
  need_ansible_vault
  need_vault_pass
  [[ -r "$CREDS_VAULT" ]] || die "encrypted creds not found: ${CREDS_VAULT}"
  ansible-vault edit "$CREDS_VAULT" --vault-password-file "$VAULT_PASS"
}

cmd_view() {
  need_ansible_vault
  need_vault_pass
  [[ -r "$CREDS_VAULT" ]] || die "encrypted creds not found: ${CREDS_VAULT}"
  ansible-vault view "$CREDS_VAULT" --vault-password-file "$VAULT_PASS"
}

cmd_decrypt() {
  need_ansible_vault
  need_vault_pass
  [[ -r "$CREDS_VAULT" ]] || die "encrypted creds not found: ${CREDS_VAULT}"
  [[ ! -e "$CREDS_PLAIN" ]] || die "${CREDS_PLAIN} already exists; move it aside first"
  ansible-vault decrypt "$CREDS_VAULT" \
    --vault-password-file "$VAULT_PASS" \
    --output "$CREDS_PLAIN"
  chmod 600 "$CREDS_PLAIN"
  info "decrypted -> ${CREDS_PLAIN}"
}

cmd_materialize() {
  need_ansible_vault
  need_vault_pass
  [[ -r "$CREDS_VAULT" ]] || die "encrypted creds not found: ${CREDS_VAULT}"
  ansible-vault view "$CREDS_VAULT" --vault-password-file "$VAULT_PASS"
}

cmd_status() {
  printf 'CREDS_PLAIN=%s\n' "$CREDS_PLAIN"
  printf 'CREDS_VAULT=%s\n' "$CREDS_VAULT"
  printf 'VAULT_PASS=%s\n' "$VAULT_PASS"
  [[ -r "$CREDS_PLAIN" ]] && printf '  plain:   present\n' || printf '  plain:   absent\n'
  [[ -r "$CREDS_VAULT" ]] && printf '  vault:   present\n' || printf '  vault:   absent\n'
  [[ -r "$VAULT_PASS" ]] && printf '  passfile: present\n' || printf '  passfile: absent\n'
}

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    encrypt) cmd_encrypt "$@" ;;
    edit) cmd_edit "$@" ;;
    view) cmd_view "$@" ;;
    decrypt) cmd_decrypt "$@" ;;
    materialize|export) cmd_materialize "$@" ;;
    status) cmd_status "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown command: ${cmd} (try: help)" ;;
  esac
}

main "$@"
