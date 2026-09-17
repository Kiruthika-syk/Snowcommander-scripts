#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SECURITYTOOLS_ENV:-${BASE_DIR}/securitytools.env}"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: subscription configuration is not readable: $CONFIG_FILE" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

USERNAME="${RHSM_USERNAME:-}"
PASSWORD="${RHSM_PASSWORD:-}"

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    echo "ERROR: RHSM_USERNAME and RHSM_PASSWORD must be set in $CONFIG_FILE" >&2
    exit 1
fi
 
# Install subscription-manager if not installed
yum list installed subscription-manager &> /dev/null || {
    echo "Installing subscription-manager..."
    sudo yum install -y subscription-manager
}
 
# Clean subscription manager
echo "Cleaning subscription manager..."
sudo subscription-manager clean
 
# Register the system
echo "Registering the system..."
sudo subscription-manager register --username="$USERNAME" --password="$PASSWORD" --auto-attach
 
#Refresh subscription-manager
#sudo subscription-manager refresh
# Enable required repositories for RHEL 9
echo "Enabling RHEL 9 repositories..."
sudo subscription-manager repos --enable rhel-9-for-x86_64-baseos-rpms
sudo subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms  # Fixed typo
 
# Update repolist
echo "Updating repository list..."
sudo yum repolist
 
echo "RHEL 9 system successfully registered"
