#!/usr/bin/env bash
# Azure Portal Linux onboarding script — STRUCTURE ONLY (no secrets in git).
# Production targets run sentinel_core.sh with values from securitytools.env / vault.
#
# Portal variable              →  Snowcommander env
# servicePrincipalClientId     →  AZCM_SP_CLIENT_ID
# servicePrincipalSecret       →  AZCM_SP_SECRET
# subscriptionId               →  AZCM_SUBSCRIPTION_ID
# resourceGroup                →  AZCM_RESOURCE_GROUP
# tenantId                     →  AZCM_TENANT_ID
# location                     →  AZCM_LOCATION
# correlationId                →  AZCM_CORRELATION_ID
# cloud                        →  AZCM_CLOUD
#
# Run on jump host (after creds materialized):
#   set -a; source securitytools.env; set +a
#   ./sentinel_core.sh

set -euo pipefail

: "${AZCM_SP_CLIENT_ID:?}"
: "${AZCM_SP_SECRET:?}"
: "${AZCM_SUBSCRIPTION_ID:?}"
: "${AZCM_RESOURCE_GROUP:?}"
: "${AZCM_TENANT_ID:?}"

export subscriptionId="${AZCM_SUBSCRIPTION_ID}"
export resourceGroup="${AZCM_RESOURCE_GROUP}"
export tenantId="${AZCM_TENANT_ID}"
export location="${AZCM_LOCATION:-eastus2}"
export authType="principal"
export correlationId="${AZCM_CORRELATION_ID:-d1cf0499-18e4-47cb-ae37-0d85892d63df}"
export cloud="${AZCM_CLOUD:-AzureCloud}"

servicePrincipalClientId="${AZCM_SP_CLIENT_ID}"
servicePrincipalSecret="${AZCM_SP_SECRET}"

output=$(wget https://aka.ms/azcmagent -O ~/install_linux_azcmagent.sh 2>&1)
if [ $? != 0 ]; then
  wget -qO- --method=PUT --body-data="{\"subscriptionId\":\"$subscriptionId\",\"resourceGroup\":\"$resourceGroup\",\"tenantId\":\"$tenantId\",\"location\":\"$location\",\"correlationId\":\"$correlationId\",\"authType\":\"$authType\",\"operation\":\"onboarding\",\"messageType\":\"DownloadScriptFailed\",\"message\":\"$output\"}" "https://gbl.his.arc.azure.com/log" &>/dev/null || true
fi
echo "$output"
bash ~/install_linux_azcmagent.sh
sudo azcmagent connect \
  --service-principal-id "$servicePrincipalClientId" \
  --service-principal-secret "$servicePrincipalSecret" \
  --resource-group "$resourceGroup" \
  --tenant-id "$tenantId" \
  --location "$location" \
  --subscription-id "$subscriptionId" \
  --cloud "$cloud" \
  --tags "${AZCM_TAGS:-'Cost Center'=1392,'Resource Owner'=parthav.reddy1@stryker.com}" \
  --correlation-id "$correlationId"
