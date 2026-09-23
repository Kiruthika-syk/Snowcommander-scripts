#!/usr/bin/env bash
# ==============================================================================
# Sentinel unified operator script (Install + Reconnect — same path)
# Portal uploads this to targets; credentials injected via environment.
# ==============================================================================
set -euo pipefail

portal_sudo() {
  if sudo -n true 2>/dev/null; then
    sudo -n "$@"
  elif [ -n "${PORTAL_SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$PORTAL_SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

oracle_linux_azcm_repo_prep() {
  # Only Oracle Linux 8 VMs need this cleanup; leave RHEL/CentOS/Ubuntu unchanged.
  local os_id="" version_id="" major=""
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
  fi
  major="${version_id%%.*}"
  if [ "$os_id" != "ol" ] && [ "$os_id" != "oracle" ] && [ "$os_id" != "oraclelinux" ]; then
    return 0
  fi
  if [ "$major" != "8" ]; then
    echo "=== Oracle Linux detected ($version_id), repo cleanup is configured for OL8 only - skipping ==="
    return 0
  fi
  if ! command -v dnf >/dev/null 2>&1; then
    echo "=== Oracle Linux detected, but dnf not found - skipping OL8 repo cleanup ==="
    return 0
  fi

  echo "=== Oracle Linux 8 detected: cleaning DNF cache ==="
  portal_sudo dnf clean all || true
  portal_sudo rm -rf /var/cache/dnf || true

  echo "=== Checking repo files ==="
  ls /etc/yum.repos.d/ 2>/dev/null || true

  echo "=== Disabling CentOS Stream repos if present ==="
  portal_sudo dnf install -y dnf-plugins-core 2>/dev/null || true
  portal_sudo dnf config-manager --disable 'centos*' 2>/dev/null || true
  portal_sudo dnf config-manager --disable appstream 2>/dev/null || true

  echo "=== Removing CentOS repo files ==="
  portal_sudo rm -f /etc/yum.repos.d/CentOS* 2>/dev/null || true
  portal_sudo rm -f /etc/yum.repos.d/appstream.repo 2>/dev/null || true

  echo "=== Enabling correct Oracle Linux 8 repos ==="
  portal_sudo dnf config-manager --enable ol8_baseos_latest || true
  portal_sudo dnf config-manager --enable ol8_appstream || true

  echo "=== Active repositories ==="
  portal_sudo dnf repolist || true

  echo "=== Reinstalling Microsoft packages repo ==="
  portal_sudo rpm -Uvh --replacepkgs https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm || true
  portal_sudo dnf clean all || true
}

arc_telemetry() {
  local message_type="$1"
  local message="$2"
  local body
  body=$(printf '{"subscriptionId":"%s","resourceGroup":"%s","tenantId":"%s","location":"%s","correlationId":"%s","authType":"principal","operation":"onboarding","messageType":"%s","message":"%s"}' \
    "${AZURE_SUBSCRIPTION_ID:-}" "${AZURE_RESOURCE_GROUP:-}" "${AZURE_TENANT_ID:-}" \
    "${AZURE_LOCATION:-eastus2}" "${CORRELATION_ID:-}" "$message_type" "$message")
  if command -v wget >/dev/null 2>&1; then
    wget -qO- --method=PUT --body-data="$body" "https://gbl.his.arc.azure.com/log" &>/dev/null || true
  elif command -v curl >/dev/null 2>&1; then
    curl -fsS -X PUT -H "Content-Type: application/json" -d "$body" "https://gbl.his.arc.azure.com/log" &>/dev/null || true
  fi
}

arc_agent_show() {
  azcmagent show 2>/dev/null || true
}

arc_is_connected() {
  arc_agent_show | grep -qiE 'Agent Status[^:]*:[[:space:]]*Connected'
}

arc_is_disconnected() {
  arc_agent_show | grep -qiE 'Agent Status[^:]*:[[:space:]]*Disconnected'
}

azcmagent_installed() {
  command -v azcmagent >/dev/null 2>&1 && rpm -q azcmagent >/dev/null 2>&1
}

default_azcm_resource_name() {
  local hint mac
  hint="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo arc)"
  mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1 | tr -d ':' || true)"
  if [ -n "$mac" ] && [ "${#mac}" -ge 6 ]; then
    printf '%s-%s' "$hint" "${mac: -6}"
  else
    printf '%s-%s' "$hint" "$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -d- -f1 || date +%s)"
  fi
}

arc_disconnect_stale() {
  if ! command -v azcmagent >/dev/null 2>&1; then
    return 0
  fi
  echo "AZCM: clearing stale local registration..."
  portal_sudo azcmagent disconnect --force-local-only 2>&1 \
    || portal_sudo azcmagent disconnect --force 2>&1 \
    || portal_sudo azcmagent disconnect 2>&1 || true
  sleep 2
}

arc_connect_error_hint() {
  local out="$1"
  if echo "$out" | grep -qiE 'AZCM0041|invalid_client|AADSTS7000222|expired.*secret|401.*Unauthorized'; then
    echo "ERROR: Azure service principal secret is invalid or expired (AZCM0041 / invalid_client)."
    echo "HINT: Rotate the client secret in Azure Portal -> App registrations -> ${AZURE_CLIENT_ID}"
    echo "      Update AZCM_SP_SECRET in securitytools.env or ~/.snowcommander-creds.env, then re-run."
    return 0
  fi
  if echo "$out" | grep -qiE 'AZCM0044|already exists'; then
    echo "ERROR: Arc machine resource name already exists in Azure."
    echo "HINT: Delete stale Arc machine in portal, or set AZCM_RESOURCE_NAME to a unique value."
    echo "      Suggested name: $(default_azcm_resource_name)"
    return 0
  fi
  return 1
}

# Accept portal names (AZURE_*) or jump-host .env names (AZCM_*)
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-${AZCM_SP_CLIENT_ID:-}}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-${AZCM_SP_SECRET:-}}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-${AZCM_TENANT_ID:-}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${AZCM_SUBSCRIPTION_ID:-}}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${AZCM_RESOURCE_GROUP:-}}"
AZURE_LOCATION="${AZURE_LOCATION:-${AZCM_LOCATION:-eastus2}}"
AZURE_CLOUD="${AZURE_CLOUD:-${AZCM_CLOUD:-AzureCloud}}"
CORRELATION_ID="${CORRELATION_ID:-${AZCM_CORRELATION_ID:-blr-usa-unified-fallback}}"
AZCM_TAGS="${AZCM_TAGS:-Owner=Swetha Palankar & Partha Nayak,Environment=Production,SyncNode=BLR-USA}"

for v in AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: $v is not set (portal must export credentials before running sentinel_core.sh)."
    exit 1
  fi
done

if echo "$AZURE_CLIENT_SECRET" | grep -qiE 'REPLACE|CHANGEME|YOUR_.*SECRET|<.*>'; then
  echo "ERROR: AZCM_SP_SECRET appears to be a placeholder; set a valid service principal secret."
  exit 1
fi

# 1. Inline wget provision
if ! command -v wget &>/dev/null; then
  echo "wget missing. Performing rapid inline provision..."
  if command -v apt-get &>/dev/null; then
    portal_sudo apt-get update -y && portal_sudo apt-get install -y wget
  elif command -v yum &>/dev/null; then
    portal_sudo yum install -y wget
  elif command -v dnf &>/dev/null; then
    portal_sudo dnf install -y wget
  fi
fi
if ! command -v wget &>/dev/null; then
  echo "ERROR: wget is not available after install attempt."
  arc_telemetry "DownloadScriptFailed" "wget not installed"
  exit 1
fi

INSTALLER="${HOME}/install_linux_azcmagent.sh"

oracle_linux_azcm_repo_prep

# 2. Install azcmagent package (skip download when already present)
if azcmagent_installed && [ "${SENTINEL_FORCE_REINSTALL:-0}" != "1" ]; then
  echo "azcmagent package already installed; skipping installer download"
else
  echo "Downloading https://aka.ms/azcmagent → $INSTALLER"
  if ! output=$(wget https://aka.ms/azcmagent -O "$INSTALLER" 2>&1); then
    echo "Download failed. Routing telemetry to gbl.his.arc.azure.com..."
    echo "$output"
    arc_telemetry "DownloadScriptFailed" "$output"
    exit 1
  fi
  echo "$output"
  chmod 755 "$INSTALLER"

  if ! portal_sudo bash "$INSTALLER"; then
    echo "Installation execution failed. Routing telemetry to gbl.his.arc.azure.com..."
    arc_telemetry "InstallScriptFailed" "bash install_linux_azcmagent.sh failed"
    exit 1
  fi
fi

command -v azcmagent >/dev/null 2>&1 || {
  echo "ERROR: azcmagent is not available after install attempt."
  exit 1
}

# 3. Connect — force-clear stale Disconnected registration, then connect
AZCM_DISCONNECT_BEFORE_CONNECT="${AZCM_DISCONNECT_BEFORE_CONNECT:-1}"
need_disconnect=0
if [ "$AZCM_DISCONNECT_BEFORE_CONNECT" = "1" ] || [ "$AZCM_DISCONNECT_BEFORE_CONNECT" = "true" ]; then
  need_disconnect=1
fi
if arc_is_disconnected; then
  echo "AZCM: agent is Disconnected; forcing local disconnect before reconnect"
  need_disconnect=1
fi
if [ "$need_disconnect" -eq 1 ]; then
  arc_disconnect_stale
fi

if [ -z "${AZCM_RESOURCE_NAME:-}" ]; then
  AZCM_RESOURCE_NAME="$(default_azcm_resource_name)"
  echo "AZCM: using resource name ${AZCM_RESOURCE_NAME} (set AZCM_RESOURCE_NAME to override)"
fi

echo "Executing azcmagent connect to ${AZURE_LOCATION} as ${AZCM_RESOURCE_NAME}..."
connect_args=(
  --service-principal-id "$AZURE_CLIENT_ID"
  --service-principal-secret "$AZURE_CLIENT_SECRET"
  --tenant-id "$AZURE_TENANT_ID"
  --subscription-id "$AZURE_SUBSCRIPTION_ID"
  --resource-group "$AZURE_RESOURCE_GROUP"
  --location "$AZURE_LOCATION"
  --cloud "$AZURE_CLOUD"
  --correlation-id "$CORRELATION_ID"
  --tags "$AZCM_TAGS"
  --resource-name "$AZCM_RESOURCE_NAME"
)

set +e
connect_out=$(portal_sudo azcmagent connect "${connect_args[@]}" 2>&1)
connect_status=$?
set -e
echo "$connect_out"

if [ "$connect_status" -ne 0 ] \
  || echo "$connect_out" | grep -qiE 'level=fatal|AZCM004[0-9]|invalid_client|already exists|401.*Unauthorized'; then
  arc_connect_error_hint "$connect_out" || echo "ERROR: azcmagent connect failed."
  arc_telemetry "ConnectFailed" "$(echo "$connect_out" | tail -5 | tr '\n' ' ')"
  exit 1
fi

if ! arc_is_connected; then
  echo "ERROR: azcmagent connect finished but agent is not Connected."
  azcmagent show 2>&1 | head -n 20 || true
  arc_telemetry "ConnectFailed" "agent not connected after connect"
  exit 1
fi

echo "Sentinel execution sequence completed successfully."
azcmagent show 2>&1 | head -n 40 || true
