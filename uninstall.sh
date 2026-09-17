#!/usr/bin/env bash

#

# uninstall_security_tools.sh

#

# Enterprise Security Tools Cleanup Script

#

# Usage:

#   sudo ./uninstall_security_tools.sh all

#   sudo ./uninstall_security_tools.sh tanium crowdstrike sentinel cmdbsync syslog

#   sudo ./uninstall_security_tools.sh verify

#



set -uo pipefail

IFS=$'\n\t'

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SECURITYTOOLS_ENV:-${BASE_DIR}/securitytools.env}"

if [[ -r "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
fi

load_sudo_password() {
    if [[ -n "${PORTAL_SUDO_PASSWORD:-}" ]]; then
        printf '%s\n' "$PORTAL_SUDO_PASSWORD"
        return 0
    fi
    if [[ -n "${SSHPASS:-}" ]]; then
        printf '%s\n' "$SSHPASS"
        return 0
    fi

    local credentials
    for credentials in \
        /home/tpx-admin/crowdstrike/.ssh_credentials \
        /home/tpx-admin/may/ssh_fleet.env; do
        [[ -r "$credentials" ]] || continue
        # shellcheck source=/dev/null
        source "$credentials" 2>/dev/null || true
        if [[ -n "${SSHPASS:-}" ]]; then
            printf '%s\n' "$SSHPASS"
            return 0
        fi
        if [[ -n "${SSH_PASS:-}" ]]; then
            printf '%s\n' "$SSH_PASS"
            return 0
        fi
    done
    return 1
}

if [[ $EUID -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        exec sudo -n bash "$0" "$@"
    fi

    sudo_password="$(load_sudo_password || true)"
    if [[ -z "$sudo_password" ]]; then
        echo "ERROR: root privileges are required; run with sudo or configure the protected sudo credential." >&2
        exit 1
    fi
    printf '%s\n' "$sudo_password" | sudo -S -p '' bash "$0" "$@"
    exit $?
fi



###############################################################################

# Configuration

###############################################################################



LOG_FILE="/var/log/securitytools-uninstall.log"



mkdir -p "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"



exec > >(tee -a "$LOG_FILE") 2>&1



SUCCEEDED=()

FAILED=()



###############################################################################

# Logging

###############################################################################



timestamp() {

    date "+%F %T"

}



info() {

    echo "[INFO]    $(timestamp) $*"

}



success() {

    echo "[SUCCESS] $(timestamp) $*"

}



warn() {

    echo "[WARNING] $(timestamp) $*"

}



error() {

    echo "[ERROR]   $(timestamp) $*"

}



###############################################################################

# Helpers

###############################################################################



stop_service() {



    local svc="$1"



    if systemctl list-unit-files | grep -q "^${svc}"; then



        systemctl stop "$svc" 2>/dev/null || true

        systemctl disable "$svc" 2>/dev/null || true



    fi

}



remove_package() {



    local pkg="$1"



    if rpm -q "$pkg" >/dev/null 2>&1; then



        if command -v dnf >/dev/null 2>&1; then



            dnf remove -y "$pkg" >/dev/null 2>&1 || true



        elif command -v yum >/dev/null 2>&1; then



            yum remove -y "$pkg" >/dev/null 2>&1 || true



        fi



        rpm -e "$pkg" >/dev/null 2>&1 || true



    fi

}



remove_directory() {



    local dir="$1"



    [[ -d "$dir" ]] && rm -rf "$dir"

}



remove_file() {



    local file="$1"



    [[ -e "$file" ]] && rm -f "$file"

}



reload_systemd() {



    systemctl daemon-reload >/dev/null 2>&1 || true

    systemctl reset-failed >/dev/null 2>&1 || true

}



run_remove() {



    local component="$1"



    info "========================================================"

    info "Removing $component"

    info "========================================================"



    if "remove_${component}"; then



        SUCCEEDED+=("$component")

        success "$component removed"



    else



        FAILED+=("$component")

        error "$component removal failed"



    fi

}



###############################################################################

# Tanium

###############################################################################



remove_tanium() {



    stop_service taniumclient.service

    stop_service taniumclient



    remove_package TaniumClient



    remove_directory /opt/Tanium

    remove_directory /var/lib/Tanium

    remove_directory /var/log/Tanium

    remove_directory /etc/opt/Tanium



    remove_file /usr/lib/systemd/system/taniumclient.service

    remove_file /etc/systemd/system/taniumclient.service



    reload_systemd



    success "Tanium cleanup complete"

}



###############################################################################

# CrowdStrike

###############################################################################



remove_crowdstrike() {



    stop_service falcon-sensor.service

    stop_service falcon-sensor



    remove_package falcon-sensor



    remove_directory /opt/CrowdStrike

    remove_directory /etc/CrowdStrike

    remove_directory /etc/opt/CrowdStrike

    remove_directory /var/lib/falcon-sensor

    remove_directory /var/log/falcon-sensor

    remove_directory /var/cache/falcon-sensor



    remove_file /usr/lib/systemd/system/falcon-sensor.service

    remove_file /etc/systemd/system/falcon-sensor.service



    find /etc/systemd -name "*falcon*" -delete 2>/dev/null || true



    reload_systemd



    success "CrowdStrike cleanup complete"

}



###############################################################################

# Azure Arc / Sentinel

###############################################################################



remove_sentinel() {



    if command -v azcmagent >/dev/null 2>&1; then



        azcmagent disconnect --force >/dev/null 2>&1 || true



    fi



    remove_package azcmagent



    remove_directory /opt/azcmagent

    remove_directory /etc/opt/azcmagent

    remove_directory /var/opt/azcmagent

    remove_directory /var/lib/GuestConfig



    reload_systemd



    success "Azure Arc cleanup complete"

}



###############################################################################

# CMDB Sync

###############################################################################



remove_cmdbsync() {



    remove_file /etc/sudoers.d/cmdbsync



    if id cmdbsync >/dev/null 2>&1; then



        userdel -r cmdbsync >/dev/null 2>&1 || true



    fi



    if getent group cmdbsync >/dev/null; then



        groupdel cmdbsync >/dev/null 2>&1 || true



    fi



    remove_directory /home/cmdbsync

    remove_file /var/spool/mail/cmdbsync



    success "CMDB Sync removed"

}



###############################################################################

# Syslog

###############################################################################



remove_syslog() {



    remove_file /etc/rsyslog.d/60-securitytools-remote.conf



    systemctl restart rsyslog >/dev/null 2>&1 || true



    if command -v rsyslogd >/dev/null 2>&1; then



        rsyslogd -N1 >/dev/null 2>&1 || true



    fi



    success "Security rsyslog configuration removed"

}



###############################################################################

# Verification

###############################################################################



verify_package() {



    local pkg="$1"



    if rpm -q "$pkg" >/dev/null 2>&1; then



        printf "%-25s : PRESENT\n" "$pkg"



    else



        printf "%-25s : REMOVED\n" "$pkg"



    fi

}



verify_service() {



    local svc="$1"



    if systemctl list-unit-files | grep -q "^${svc}"; then



        printf "%-25s : PRESENT\n" "$svc"



    else



        printf "%-25s : REMOVED\n" "$svc"



    fi

}



verify_directory() {



    local dir="$1"



    if [[ -d "$dir" ]]; then



        printf "%-25s : PRESENT\n" "$dir"



    else



        printf "%-25s : REMOVED\n" "$dir"



    fi

}



verify() {



    echo

    echo "========================================================"

    echo "Verification"

    echo "========================================================"



    echo

    echo "Packages"

    echo "--------"



    verify_package TaniumClient

    verify_package falcon-sensor

    verify_package azcmagent



    echo

    echo "Services"

    echo "--------"



    verify_service taniumclient.service

    verify_service falcon-sensor.service



    echo

    echo "Directories"

    echo "-----------"



    verify_directory /opt/Tanium

    verify_directory /opt/CrowdStrike

    verify_directory /var/lib/falcon-sensor

    verify_directory /var/opt/azcmagent



    echo

    echo "CMDB Sync"

    echo "---------"



    if id cmdbsync >/dev/null 2>&1; then



        echo "User           : PRESENT"



    else



        echo "User           : REMOVED"



    fi



    if [[ -f /etc/sudoers.d/cmdbsync ]]; then



        echo "Sudoers File   : PRESENT"



    else



        echo "Sudoers File   : REMOVED"



    fi



    echo

    echo "Syslog"



    if [[ -f /etc/rsyslog.d/60-securitytools-remote.conf ]]; then



        echo "Remote Config  : PRESENT"



    else



        echo "Remote Config  : REMOVED"



    fi



    echo

}



###############################################################################

# Summary

###############################################################################



summary() {



    echo

    echo "========================================================"

    echo "Security Tools Removal Summary"

    echo "========================================================"



    echo



    echo "Succeeded:"

    if [[ ${#SUCCEEDED[@]} -eq 0 ]]; then

        echo "  None"

    else

        for item in "${SUCCEEDED[@]}"; do

            echo "  ✔ $item"

        done

    fi



    echo



    echo "Failed:"

    if [[ ${#FAILED[@]} -eq 0 ]]; then

        echo "  None"

    else

        for item in "${FAILED[@]}"; do

            echo "  ✘ $item"

        done

    fi



    echo

    echo "Log File : $LOG_FILE"

    echo

}



###############################################################################

# Main

###############################################################################



main() {



    if [[ $EUID -ne 0 ]]; then



        error "Run this script as root or with sudo."

        exit 1



    fi



    if [[ $# -eq 0 ]]; then



        set -- all



    fi



    if [[ "$1" == "verify" ]]; then



        verify

        exit 0



    fi



    if [[ "$1" == "all" ]]; then



        set -- tanium crowdstrike sentinel cmdbsync syslog



    fi



    for component in "$@"; do



        case "$component" in



            tanium|crowdstrike|sentinel|cmdbsync|syslog)



                run_remove "$component"

                ;;



            *)



                error "Unknown component: $component"

                FAILED+=("$component")

                ;;



        esac



    done



    reload_systemd



    verify



    summary

}



main "$@"
