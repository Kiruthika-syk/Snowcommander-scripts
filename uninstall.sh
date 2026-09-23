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

    local max_wait="${2:-45}"



    if timeout 10 systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then



        timeout "$max_wait" systemctl stop "$svc" 2>/dev/null || true

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



stop_arc_services() {



    local svc



    # Kill processes first — systemctl stop on Arc units can hang indefinitely.

    for svc in himdsd arcproxyd extd gcad; do



        pkill -x "$svc" 2>/dev/null || true



    done



    for svc in himdsd arcproxyd extd gcad azcmagent; do



        stop_service "${svc}.service" 30

        stop_service "$svc" 30



    done



    sleep 1



}



arc_disconnect_local() {



    if ! command -v azcmagent >/dev/null 2>&1; then

        return 1

    fi



    local out="" rc=0



    out=$(timeout 90 azcmagent disconnect --force-local-only 2>&1) || rc=$?

    printf '%s\n' "$out"



    if echo "$out" | grep -qiE 'Disconnected machine from Azure|Resource is already deleted'; then

        return 0

    fi



    if [[ "$rc" -eq 124 ]]; then

        warn "azcmagent disconnect timed out after 90s"

        return 0

    fi



    if [[ "$rc" -ne 0 ]]; then

        out=$(timeout 60 azcmagent disconnect --force 2>&1) || true

        printf '%s\n' "$out"

        echo "$out" | grep -qiE 'Disconnected machine from Azure|Resource is already deleted' && return 0

        timeout 30 azcmagent disconnect 2>/dev/null || true

    fi



    return 1

}



arc_kill_processes() {



    local svc



    for svc in himdsd arcproxyd extd gcad; do

        pkill -x "$svc" 2>/dev/null || true

    done



}



arc_rpm_installed() {



    rpm -q azcmagent >/dev/null 2>&1



}



arc_purge_binaries() {



    local f



    for f in /usr/bin/azcmagent /usr/local/bin/azcmagent /usr/sbin/azcmagent \
             /opt/azcmagent/bin/azcmagent; do

        remove_file "$f"

    done



    hash -r 2>/dev/null || true



}



arc_purge_package() {



    remove_package azcmagent



    if arc_rpm_installed; then

        warn "azcmagent rpm still registered — forcing removal"

        rpm -e --nodeps azcmagent >/dev/null 2>&1 || true

    fi



    hash -r 2>/dev/null || true



}



arc_verify_clean() {



    local dir bin



    hash -r 2>/dev/null || true



    bin="$(type -p azcmagent 2>/dev/null || true)"

    if [[ -n "$bin" && -x "$bin" ]]; then

        error "azcmagent binary still present: ${bin}"

        return 1

    fi



    if arc_rpm_installed; then

        error "azcmagent package still registered in rpm"

        return 1

    fi



    for dir in /opt/azcmagent /etc/opt/azcmagent /var/opt/azcmagent; do

        if [[ -d "$dir" ]]; then

            error "Arc directory still present: ${dir}"

            return 1

        fi

    done



    return 0



}



remove_sentinel() {



    info "Stopping Azure Arc services"

    stop_arc_services



    local arc_disconnected=0

    if command -v azcmagent >/dev/null 2>&1; then

        info "Disconnecting stale Arc registration"

        if arc_disconnect_local; then

            arc_disconnected=1

            info "Arc disconnected — proceeding to package removal (skipping extended service stop)"

        else

            warn "Arc disconnect did not confirm success — forcing local cleanup"

            arc_disconnected=1

        fi

    elif arc_rpm_installed || [[ -d /opt/azcmagent ]]; then

        info "azcmagent not in PATH — skipping disconnect, forcing local cleanup"

        arc_disconnected=1

    fi



    if (( arc_disconnected )); then

        arc_kill_processes

    else

        stop_arc_services

    fi



    arc_purge_package

    arc_purge_binaries



    # Paths left by install_linux_azcmagent.sh and disconnected registrations.

    remove_directory /opt/azcmagent

    remove_directory /etc/opt/azcmagent

    remove_directory /var/opt/azcmagent

    remove_directory /var/lib/GuestConfig

    remove_directory /var/lib/azcmagent

    remove_file /usr/sbin/gcad

    remove_file /etc/cron.d/azcmagent_autoupgrade



    for f in /root/install_linux_azcmagent.sh \
               /home/tpx-admin/install_linux_azcmagent.sh \
               "${HOME}/install_linux_azcmagent.sh"; do



        remove_file "$f"



    done



    # Drop any leftover unit files not owned by the rpm anymore.

    for f in /etc/systemd/system/himdsd.service \
               /etc/systemd/system/arcproxyd.service \
               /etc/systemd/system/extd.service \
               /etc/systemd/system/gcad.service; do



        remove_file "$f"



    done



    reload_systemd



    if arc_verify_clean; then

        success "Azure Arc cleanup complete"

        return 0

    fi



    warn "Arc cleanup incomplete — retrying forced purge"

    arc_kill_processes

    arc_purge_package

    arc_purge_binaries

    remove_directory /opt/azcmagent

    remove_directory /etc/opt/azcmagent

    remove_directory /var/opt/azcmagent

    reload_systemd



    if arc_verify_clean; then

        success "Azure Arc cleanup complete (after forced purge)"

        return 0

    fi



    return 1



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

    verify_service himdsd.service

    verify_service arcproxyd.service

    verify_service extd.service



    echo

    echo "Directories"

    echo "-----------"



    verify_directory /opt/Tanium

    verify_directory /opt/CrowdStrike

    verify_directory /var/lib/falcon-sensor

    verify_directory /opt/azcmagent

    verify_directory /etc/opt/azcmagent

    verify_directory /var/opt/azcmagent

    verify_directory /var/lib/GuestConfig



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
