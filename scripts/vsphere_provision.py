#!/usr/bin/env python3
"""
vsphere_provision.py - vSphere stages of the end-to-end validation harness.

Covers stages 1-3:
    1. connect to vCenter
    2. find the template
    3. produce a VM from it, connect the NIC, power on, report the IP

Two ways to produce a VM, and the difference matters:

    clone    (default)  CloneVM_Task creates a NEW VM and leaves the template
                        intact. Almost always what you want.

    convert  (opt-in)   MarkAsVirtualMachine converts the template ITSELF into
                        a VM. It stops being a template, and the golden image
                        is contaminated as soon as an agent registers against
                        it. Requires --i-understand-this-destroys-the-template.

Credentials come from the environment (VCENTER_USER / VCENTER_PASSWORD) so they
never land on a command line where `ps` could read them.

Progress goes to stderr; a single JSON object goes to stdout on success, so a
shell caller can parse the result cleanly.

Exit codes: 0 ok, 2 usage, 3 connect failed, 4 template not found,
            5 clone/convert failed, 6 power-on or IP timeout
"""

from __future__ import annotations

import argparse
import atexit
import base64
import json
import os
import re
import shlex
import ssl
import sys
import time
import urllib.request

from pyVim import connect
from pyVmomi import vim, vmodl

RC_OK, RC_USAGE, RC_CONNECT, RC_NOTFOUND, RC_CLONE, RC_POWER = 0, 2, 3, 4, 5, 6
RC_SCOPE, RC_GUEST = 7, 8

# ----------------------------------------------------------------------------
# Hard scope guardrail.
#
# This tool may only ever touch objects inside the SnowCommander/Templates
# folder. Anything outside it is refused before a single API call that could
# modify state. The regex tolerates the "SnowComander" spelling that exists in
# the BLR inventory as well as the correctly spelled variant.
# ----------------------------------------------------------------------------
# Folder naming differs between sites, so the pattern tolerates both observed
# variants rather than forcing the inventory to be renamed:
#   BLR  SnowComander/Templates   (one 'm', plural)
#   FW   SnowCommander/Template   (two 'm', singular)
# Override with SNOWCOMMANDER_FOLDER_RE if a site uses a different convention.
ALLOWED_FOLDER_RE = re.compile(
    os.environ.get("SNOWCOMMANDER_FOLDER_RE", r"snowcom+ander/templates?"),
    re.IGNORECASE)
ALLOWED_FOLDER_LABEL = "SnowCommander/Template(s)"


def normalise_path(path: str) -> str:
    """Lowercase and strip separators so folder spellings compare reliably."""
    return re.sub(r"[\s_\-]+", "", path).lower()


def enforce_scope(obj, path: str) -> None:
    """Refuse to act on anything outside SnowCommander/Templates."""
    if not ALLOWED_FOLDER_RE.search(normalise_path(path)):
        fail(RC_SCOPE,
             f"SCOPE VIOLATION: '{obj.name}' lives in '{path or '<root>'}', "
             f"outside {ALLOWED_FOLDER_LABEL}. This tool is restricted to that "
             f"folder and will not touch any other object.")
    log("SCOPE", f"'{obj.name}' is inside {path} - within the permitted scope")


def log(stage: str, msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [{stage}] {msg}",
          file=sys.stderr, flush=True)


def fail(code: int, msg: str) -> None:
    log("ERROR", msg)
    sys.exit(code)


# ----------------------------------------------------------------------------
# Stage 1 - connect
# ----------------------------------------------------------------------------
def connect_vcenter(host: str, user: str, password: str, insecure: bool):
    log("1/8 CONNECT", f"connecting to vCenter {host} as {user}")
    ctx = None
    if insecure:
        ctx = ssl._create_unverified_context()
        log("1/8 CONNECT", "TLS certificate verification DISABLED (--insecure)")
    try:
        si = connect.SmartConnect(host=host, user=user, pwd=password,
                                  sslContext=ctx, port=443)
    except vim.fault.InvalidLogin:
        fail(RC_CONNECT, f"invalid credentials for {host}")
    except Exception as exc:  # noqa: BLE001
        hint = ""
        if "certificate verify failed" in str(exc):
            hint = " (self-signed certificate? re-run with --insecure)"
        fail(RC_CONNECT, f"cannot connect to {host}: {exc}{hint}")

    atexit.register(connect.Disconnect, si)
    log("1/8 CONNECT", f"connected: {si.content.about.fullName}")
    return si


def get_all(content, vimtype, container=None):
    view = content.viewManager.CreateContainerView(
        container or content.rootFolder, [vimtype], True)
    try:
        return list(view.view)
    finally:
        view.Destroy()


def bulk_fetch(content, container, vimtype, paths):
    """Retrieve properties for every object of a type in ONE round trip.

    Touching vm.config.template in a loop makes pyVmomi issue a separate SOAP
    call per VM, which takes many minutes on a large vCenter. PropertyCollector
    returns everything at once instead.

    Returns [(managed_object, {path: value}), ...].
    """
    view = content.viewManager.CreateContainerView(container, [vimtype], True)
    try:
        traversal = vmodl.query.PropertyCollector.TraversalSpec(
            name="toView", path="view", skip=False, type=vim.view.ContainerView)
        obj_spec = vmodl.query.PropertyCollector.ObjectSpec(
            obj=view, skip=True, selectSet=[traversal])
        prop_spec = vmodl.query.PropertyCollector.PropertySpec(
            type=vimtype, pathSet=list(paths), all=False)
        filter_spec = vmodl.query.PropertyCollector.FilterSpec(
            objectSet=[obj_spec], propSet=[prop_spec])

        results = []
        for obj in content.propertyCollector.RetrieveContents([filter_spec]) or []:
            props = {p.name: p.val for p in (obj.propSet or [])}
            results.append((obj.obj, props))
        return results
    finally:
        view.Destroy()


def find_templates_folder(content):
    """Locate the SnowCommander/Templates folder.

    Scoping the search to this folder is what keeps enumeration fast: only its
    children are inspected instead of every VM in the vCenter. Folders are few,
    so walking them is cheap.
    """
    log("2/8 TEMPLATE", f"locating the {ALLOWED_FOLDER_LABEL} folder")
    candidates = []
    for folder, props in bulk_fetch(content, content.rootFolder, vim.Folder, ["name"]):
        # Accept both 'Template' and 'Templates'.
        if normalise_path(props.get("name", "")) not in ("template", "templates"):
            continue
        path = folder_path(folder)
        full = f"{path}/{props.get('name')}" if path else props.get("name", "")
        if ALLOWED_FOLDER_RE.search(normalise_path(full)):
            candidates.append((folder, full))

    if not candidates:
        # Do not silently fall back to scanning every VM: on a populated
        # vCenter that takes many minutes and still finds nothing useful.
        log("2/8 TEMPLATE", f"no folder matching {ALLOWED_FOLDER_LABEL} was found")
        log("2/8 TEMPLATE", "run with --list-folders to see the actual inventory layout")
        fail(RC_NOTFOUND,
             f"cannot locate a folder matching '{ALLOWED_FOLDER_RE.pattern}'. "
             f"Use --list-folders to inspect the hierarchy, or set "
             f"SNOWCOMMANDER_FOLDER_RE to match this site's naming.")
    if len(candidates) > 1:
        log("2/8 TEMPLATE",
            f"{len(candidates)} matching folders found; using the first: {candidates[0][1]}")
    log("2/8 TEMPLATE", f"folder located: {candidates[0][1]}")
    return candidates[0]


def folder_path(obj) -> str:
    """Inventory path such as 'SnowComander/Templates'."""
    parts, node = [], obj.parent
    while node and hasattr(node, "name") and node.name not in ("vm", "Datacenters"):
        parts.append(node.name)
        node = getattr(node, "parent", None)
    return "/".join(reversed(parts))


# ----------------------------------------------------------------------------
# Stage 2 - find the template
# ----------------------------------------------------------------------------
def list_folders(content, needle: str | None = None) -> None:
    """Print the VM folder hierarchy, to discover the real layout.

    Read-only and unscoped on purpose: you cannot correct a folder pattern
    without first seeing what the site actually calls things.
    """
    log("FOLDERS", "enumerating the VM folder hierarchy")
    rows = []
    for folder, props in bulk_fetch(content, content.rootFolder, vim.Folder, ["name"]):
        name = props.get("name", "?")
        parent = folder_path(folder)
        full = f"{parent}/{name}" if parent else name
        if needle and needle.lower() not in full.lower():
            continue
        rows.append(full)

    if not rows:
        log("FOLDERS", "no folders matched")
        return

    marker_shown = False
    print(f"\n{'FOLDER PATH':<70} IN SCOPE", file=sys.stderr)
    print("-" * 82, file=sys.stderr)
    for path in sorted(set(rows)):
        in_scope = bool(ALLOWED_FOLDER_RE.search(normalise_path(path)))
        if in_scope:
            marker_shown = True
        print(f"{path:<70} {'YES' if in_scope else ''}", file=sys.stderr)
    log("FOLDERS", f"{len(set(rows))} folder(s)")
    if not marker_shown:
        log("FOLDERS",
            f"WARNING: nothing matches '{ALLOWED_FOLDER_RE.pattern}' - "
            f"set SNOWCOMMANDER_FOLDER_RE to match one of the paths above")


def scan_templates(content):
    """Return [(vm, name, guest_os, folder_path)] for templates in scope.

    Scoped to the Templates folder and fetched with a single PropertyCollector
    call, so this completes in seconds rather than minutes.
    """
    folder, folder_full = find_templates_folder(content)
    container = folder or content.rootFolder
    if folder is None:
        log("2/8 TEMPLATE",
            "scanning all VMs - slower; the folder could not be located")

    log("2/8 TEMPLATE", "fetching template properties in a single request")
    found = bulk_fetch(content, container, vim.VirtualMachine,
                       ["name", "config.template", "config.guestFullName"])
    log("2/8 TEMPLATE", f"inspected {len(found)} virtual machine(s)")

    rows = []
    for vm, props in found:
        if not props.get("config.template"):
            continue
        # When scoped to the folder its path is already known, so there is no
        # need to walk each VM's parent chain.
        path = folder_full if folder is not None else folder_path(vm)
        if not ALLOWED_FOLDER_RE.search(normalise_path(path or "")):
            continue
        rows.append((vm, props.get("name", "?"),
                     props.get("config.guestFullName") or "unknown", path))
    return rows


def scan_folder_vms(content):
    """Return [(vm, name, guest_os, path, is_template)] for VMs in scope."""
    folder, folder_full = find_templates_folder(content)
    container = folder or content.rootFolder
    found = bulk_fetch(content, container, vim.VirtualMachine,
                       ["name", "config.template", "config.guestFullName"])
    rows = []
    for vm, props in found:
        path = folder_full if folder is not None else folder_path(vm)
        if not ALLOWED_FOLDER_RE.search(normalise_path(path or "")):
            continue
        rows.append((vm,
                     props.get("name", "?"),
                     props.get("config.guestFullName") or "unknown",
                     path,
                     bool(props.get("config.template"))))
    return rows


def list_templates(content, folder_filter: str | None,
                   list_name: str | None = None) -> None:
    """List templates (and in-scope VMs) inside the permitted folder."""
    rows = scan_folder_vms(content)
    if folder_filter:
        rows = [r for r in rows if folder_filter.lower() in (r[3] or "").lower()]
    if list_name:
        rows = [r for r in rows if r[1] == list_name]

    templates = [r for r in rows if r[4]]
    vms = [r for r in rows if not r[4]]

    if not rows:
        log("2/8 TEMPLATE", f"nothing found inside {ALLOWED_FOLDER_LABEL}")
        return

    print(f"{'NAME':<34} {'KIND':<10} {'GUEST OS':<44} FOLDER", file=sys.stderr)
    print("-" * 120, file=sys.stderr)
    for _vm, name, guest, path, is_template in sorted(rows, key=lambda r: r[1]):
        kind = "template" if is_template else "vm"
        print(f"{name:<34} {kind:<10} {guest:<44} {path}", file=sys.stderr)

    if templates:
        log("2/8 TEMPLATE", f"{len(templates)} template(s) in scope")
    else:
        log("2/8 TEMPLATE",
            f"no templates in scope ({len(vms)} VM(s) — likely mid template-cycle; "
            f"--template-cycle reuses a VM with the same name)")


def find_template(content, name: str, folder_filter: str | None):
    log("2/8 TEMPLATE", f"searching for template '{name}'")
    rows = scan_templates(content)

    if not any(r[1] == name for r in rows):
        # Distinguish "not a template" from "not present" for a clearer error.
        for vm, props in bulk_fetch(content, content.rootFolder,
                                    vim.VirtualMachine, ["name", "config.template"]):
            if props.get("name") == name and not props.get("config.template"):
                fail(RC_NOTFOUND, f"'{name}' exists but is a VM, not a template")

    matches = [r[0] for r in rows
               if r[1] == name
               and (not folder_filter
                    or folder_filter.lower() in (r[3] or "").lower())]

    if not matches:
        fail(RC_NOTFOUND,
             f"template '{name}' not found inside {ALLOWED_FOLDER_LABEL}; "
             f"run --list-templates to see what exists there")
    if len(matches) > 1:
        fail(RC_NOTFOUND,
             f"'{name}' is ambiguous ({len(matches)} matches); narrow it with --folder")

    vm = matches[0]
    path = folder_path(vm)
    # Final gate before anything mutating can be attempted.
    enforce_scope(vm, path)
    log("2/8 TEMPLATE",
        f"found: {vm.name} | guest={vm.config.guestFullName} | folder={path}")
    return vm


# ----------------------------------------------------------------------------
# Stage 3 - produce a VM
# ----------------------------------------------------------------------------
def wait_task(task, what: str):
    while task.info.state in (vim.TaskInfo.State.running, vim.TaskInfo.State.queued):
        time.sleep(2)
    if task.info.state != vim.TaskInfo.State.success:
        fail(RC_CLONE, f"{what} failed: {getattr(task.info.error, 'msg', task.info.error)}")
    return task.info.result


def clone_template(content, template, new_name, datastore=None, folder=None,
                   resource_pool=None, portgroup=None):
    log("3/8 PROVISION",
        f"cloning '{template.name}' -> '{new_name}' (template left intact)")

    relospec = vim.vm.RelocateSpec()
    if resource_pool:
        pools = [p for p in get_all(content, vim.ResourcePool) if p.name == resource_pool]
        if not pools:
            fail(RC_CLONE, f"resource pool '{resource_pool}' not found")
        relospec.pool = pools[0]
    else:
        host = template.runtime.host
        if host and host.parent:
            relospec.pool = host.parent.resourcePool

    if datastore:
        stores = [d for d in get_all(content, vim.Datastore) if d.name == datastore]
        if not stores:
            fail(RC_CLONE, f"datastore '{datastore}' not found")
        relospec.datastore = stores[0]

    target_folder = template.parent
    if folder:
        folders = [f for f in get_all(content, vim.Folder) if f.name == folder]
        if not folders:
            fail(RC_CLONE, f"folder '{folder}' not found")
        target_folder = folders[0]

    task = template.CloneVM_Task(
        folder=target_folder, name=new_name,
        spec=vim.vm.CloneSpec(location=relospec, powerOn=False, template=False))
    vm = wait_task(task, "clone")
    log("3/8 PROVISION", f"clone complete: {vm.name}")
    return vm


def finalize_as_template(content, vm_name: str, force_off: bool = True):
    """Power off a VM and convert it back into a template.

    Used at the end of the validation cycle so the tested, cleaned machine
    becomes a golden image. MarkAsTemplate requires the VM to be powered off.
    """
    matches = [o for o, p in bulk_fetch(content, content.rootFolder,
                                        vim.VirtualMachine, ["name"])
               if p.get("name") == vm_name]
    if not matches:
        fail(RC_NOTFOUND, f"VM '{vm_name}' not found")
    vm = matches[0]

    path = folder_path(vm)
    enforce_scope(vm, path)

    if vm.config and vm.config.template:
        log("9/9 TEMPLATE", f"'{vm_name}' is already a template")
        return vm

    if vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOff:
        if not force_off:
            fail(RC_CLONE, f"'{vm_name}' is powered on; MarkAsTemplate needs it off")
        log("9/9 TEMPLATE", "shutting the guest down cleanly")
        try:
            vm.ShutdownGuest()
            deadline = time.time() + 180
            while time.time() < deadline:
                if vm.runtime.powerState == vim.VirtualMachinePowerState.poweredOff:
                    break
                time.sleep(5)
        except Exception:  # noqa: BLE001
            log("9/9 TEMPLATE", "guest shutdown unavailable (VMware Tools?)")
        if vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOff:
            log("9/9 TEMPLATE", "forcing power off")
            wait_task(vm.PowerOffVM_Task(), "power off")
    log("9/9 TEMPLATE", "powered off")

    try:
        vm.MarkAsTemplate()
    except Exception as exc:  # noqa: BLE001
        fail(RC_CLONE, f"MarkAsTemplate failed: {exc}")
    log("9/9 TEMPLATE", f"'{vm_name}' is now a template in {path}")
    return vm


def convert_template(template):
    log("3/8 PROVISION",
        f"CONVERTING '{template.name}' in place - it will NO LONGER be a template")
    host = template.runtime.host
    if not (host and host.parent):
        fail(RC_CLONE, "cannot resolve a resource pool for MarkAsVirtualMachine")
    try:
        template.MarkAsVirtualMachine(pool=host.parent.resourcePool, host=host)
    except Exception as exc:  # noqa: BLE001
        fail(RC_CLONE, f"MarkAsVirtualMachine failed: {exc}")
    log("3/8 PROVISION", f"converted: '{template.name}' is now a virtual machine")
    return template


def connect_nic(content, vm, portgroup=None):
    """Templates normally ship with the NIC disconnected at both levels."""
    nics = [d for d in vm.config.hardware.device
            if isinstance(d, vim.vm.device.VirtualEthernetCard)]
    if not nics:
        log("3/8 NIC", "WARNING: this VM has no network adapter")
        return False

    changes = []
    for nic in nics:
        spec = vim.vm.device.VirtualDeviceSpec()
        spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.edit
        spec.device = nic
        # 'connected' is now; 'startConnected' is at every boot. Both needed.
        nic.connectable = vim.vm.device.VirtualDevice.ConnectInfo(
            connected=True, startConnected=True, allowGuestControl=True)

        if portgroup:
            nets = [n for n in get_all(content, vim.Network) if n.name == portgroup]
            if not nets:
                fail(RC_CLONE, f"portgroup '{portgroup}' not found")
            net = nets[0]
            if isinstance(net, vim.dvs.DistributedVirtualPortgroup):
                backing = vim.vm.device.VirtualEthernetCard.DistributedVirtualPortBackingInfo()
                backing.port = vim.dvs.PortConnection(
                    portgroupKey=net.key,
                    switchUuid=net.config.distributedVirtualSwitch.uuid)
                nic.backing = backing
            else:
                nic.backing = vim.vm.device.VirtualEthernetCard.NetworkBackingInfo(
                    network=net, deviceName=portgroup)
            log("3/8 NIC", f"attaching {nic.deviceInfo.label} to '{portgroup}'")

        changes.append(spec)

    wait_task(vm.ReconfigVM_Task(spec=vim.vm.ConfigSpec(deviceChange=changes)),
              "NIC reconfigure")
    log("3/8 NIC", f"connected {len(changes)} adapter(s): connected + startConnected")
    return True


def power_on_and_wait(vm, timeout: int):
    if vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOn:
        log("3/8 POWER", "powering on")
        wait_task(vm.PowerOnVM_Task(), "power on")
    else:
        log("3/8 POWER", "already powered on")

    log("3/8 POWER", f"waiting up to {timeout}s for VMware Tools and an IPv4 address")
    deadline, last = time.time() + timeout, ""
    while time.time() < deadline:
        state = f"tools={vm.guest.toolsRunningStatus} ip={vm.guest.ipAddress}"
        if state != last:
            log("3/8 POWER", state)
            last = state
        ip = vm.guest.ipAddress
        if ip and ":" not in ip and not ip.startswith(("169.254.", "127.")):
            log("3/8 POWER", f"guest reachable at {ip}")
            return ip
        time.sleep(5)

    fail(RC_POWER,
         "timed out waiting for an IP. Check VMware Tools is installed in the "
         "template, the NIC is on a portgroup with DHCP, or supply a guest "
         "customization spec for a static address.")


# ----------------------------------------------------------------------------
# Guest-side SSH remedy — used when VMware Tools reports an IP but port 22 is
# closed. Runs inside the guest via Guest Operations (no SSH required).
# ----------------------------------------------------------------------------
SSH_REMEDY_LOG = "/tmp/sectools-sshd-remedy.log"

SSH_REMEDY_SCRIPT = fr"""set -euo pipefail
LOG={SSH_REMEDY_LOG}
exec >>"$LOG" 2>&1
echo "=== sshd remedy $(date -Iseconds 2>/dev/null || date) ==="

SSHD=/etc/ssh/sshd_config
test -f "$SSHD" || {{ echo "sshd_config missing"; exit 1; }}
cp -a "$SSHD" "${{SSHD}}.sectools-bak.$(date +%s)" 2>/dev/null || true

if grep -qE '^[[:space:]]*Port[[:space:]]' "$SSHD"; then
  sed -i 's/^[[:space:]]*Port[[:space:]].*/Port 22/' "$SSHD"
else
  printf '\nPort 22\n' >> "$SSHD"
fi
sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' "$SSHD"
if test -d /etc/ssh/sshd_config.d; then
  for dropin in /etc/ssh/sshd_config.d/*.conf; do
    test -f "$dropin" || continue
    sed -i '/^[[:space:]]*ListenAddress[[:space:]]/d' "$dropin" 2>/dev/null || true
  done
fi
if grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]' "$SSHD"; then
  sed -i 's/^[[:space:]]*#\?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' "$SSHD"
else
  printf 'PasswordAuthentication yes\n' >> "$SSHD"
fi

if command -v restorecon >/dev/null 2>&1; then
  restorecon -R /etc/ssh 2>/dev/null || true
fi

if ! test -x /usr/sbin/sshd; then
  echo "openssh-server missing; attempting install"
  if command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server || true
  fi
fi
/usr/sbin/sshd -t

start_sshd() {{
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "$svc" 2>/dev/null || true
    systemctl restart "$svc" 2>/dev/null || systemctl start "$svc"
    systemctl is-active --quiet "$svc"
    return
  fi
  if command -v chkconfig >/dev/null 2>&1; then
    chkconfig "$svc" on 2>/dev/null || chkconfig --level 2345 "$svc" on 2>/dev/null || true
  fi
  if command -v service >/dev/null 2>&1; then
    service "$svc" restart 2>/dev/null || service "$svc" start
    service "$svc" status >/dev/null 2>&1
    return
  fi
  /etc/init.d/"$svc" restart 2>/dev/null || /etc/init.d/"$svc" start
}}

started=0
for svc in sshd ssh; do
  if start_sshd "$svc" 2>/dev/null; then
    echo "started service: $svc"
    started=1
    break
  fi
done
if (( ! started )); then
  echo "ERROR: could not start sshd or ssh service" >&2
  systemctl status sshd 2>&1 || service sshd status 2>&1 || true
  exit 1
fi

if command -v firewall-cmd >/dev/null 2>&1 \
    && systemctl is-active firewalld >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
  if test -w /etc/sysconfig/iptables; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
  elif command -v service >/dev/null 2>&1; then
    service iptables save 2>/dev/null || true
  fi
fi

listening() {{
  local lines
  lines="$(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || true)"
  printf '%s\n' "$lines" | grep -qE '0\.0\.0\.0:22|\*:22|\[::\]:22|:::22' \
    || {{ printf '%s\n' "$lines" | grep -qE ':(22|ssh)[[:space:]]' \
         && ! printf '%s\n' "$lines" | grep -qE '127\.0\.0\.1:22'; }}
}}

for _ in $(seq 1 15); do
  if listening; then
    ss -lntp 2>/dev/null | grep -E ':(22|ssh)[[:space:]]' \
      || netstat -lntp 2>/dev/null | grep -E ':(22|ssh)[[:space:]]' || true
    echo "sshd listening on port 22"
    exit 0
  fi
  sleep 2
done

echo "ERROR: sshd is not listening on port 22 after remedy" >&2
systemctl status sshd 2>&1 || service sshd status 2>&1 || true
iptables -L INPUT -n 2>/dev/null | head -20 || true
exit 1
"""


def find_vm_by_name(content, name: str):
    """Return a powered-on VM in scope, or None."""
    for vm, props in bulk_fetch(content, content.rootFolder, vim.VirtualMachine,
                                ["name", "config.template"]):
        if props.get("name") != name or props.get("config.template"):
            continue
        enforce_scope(vm, folder_path(vm))
        return vm
    return None


def wait_for_guest_tools(vm, timeout: int = 180) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = getattr(vm.guest, "toolsRunningStatus", None)
        if status == "guestToolsRunning":
            return True
        time.sleep(3)
    return False


def guest_read_file(content, vm, auth, guest_path: str) -> str:
    """Fetch a small guest file via VMware Guest File Transfer."""
    fm = content.guestOperationsManager.fileManager
    try:
        info = fm.InitiateFileTransferFromGuest(
            vm=vm, auth=auth, guestFilePath=guest_path)
        with urllib.request.urlopen(info.url, timeout=30) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001
        log("GUEST SSH", f"could not read {guest_path}: {exc}")
        return ""


def guest_remedy_ssh(content, vm_name: str, guest_user: str, guest_pass: str,
                      sudo_pass: str | None) -> None:
    vm = find_vm_by_name(content, vm_name)
    if vm is None:
        fail(RC_NOTFOUND, f"VM '{vm_name}' not found inside {ALLOWED_FOLDER_LABEL}")

    if vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOn:
        fail(RC_GUEST, f"VM '{vm_name}' is not powered on")

    log("GUEST SSH", f"waiting for VMware Tools on '{vm_name}'")
    if not wait_for_guest_tools(vm):
        fail(RC_GUEST, "VMware Tools is not running; cannot apply in-guest SSH remedy")

    auth = vim.vm.guest.NamePasswordAuthentication(
        username=guest_user, password=guest_pass, interactiveSession=False)
    pm = content.guestOperationsManager.processManager

    encoded = base64.b64encode(SSH_REMEDY_SCRIPT.encode()).decode()
    runner = f"echo {encoded} | base64 -d | /bin/bash"
    if sudo_pass:
        inner = (
            f": > {shlex.quote(SSH_REMEDY_LOG)}; "
            f"printf '%s\\n' {shlex.quote(sudo_pass)} | sudo -S -p '' "
            f"/bin/bash -c {shlex.quote(runner)}"
        )
    else:
        inner = (
            f": > {shlex.quote(SSH_REMEDY_LOG)}; "
            f"sudo -n /bin/bash -c {shlex.quote(runner)}"
        )

    spec = vim.vm.guest.ProcessManager.ProgramSpec(
        programPath="/bin/bash", arguments=f"-lc {shlex.quote(inner)}")
    log("GUEST SSH", f"applying sshd_config remedy as {guest_user} via Guest Operations")
    try:
        pid = pm.StartProgramInGuest(vm=vm, auth=auth, spec=spec)
    except vim.fault.InvalidGuestLogin:
        fail(RC_GUEST, f"guest login failed for user '{guest_user}'")
    except Exception as exc:  # noqa: BLE001
        fail(RC_GUEST, f"Guest Operations failed: {exc}")

    log("GUEST SSH", f"remedy started (pid={pid}); waiting for completion")
    deadline = time.time() + 120
    while time.time() < deadline:
        info = pm.ListProcessesInGuest(vm=vm, auth=auth, pids=[pid])
        if info and info[0].endTime:
            rc = info[0].exitCode
            if rc == 0:
                log("GUEST SSH", "sshd remedy completed successfully")
                return
            detail = guest_read_file(content, vm, auth, SSH_REMEDY_LOG)
            if detail:
                log("GUEST SSH", "remedy log from the guest:")
                for line in detail.strip().splitlines()[-40:]:
                    log("GUEST SSH", f"  {line}")
            fail(RC_GUEST, f"sshd remedy exited with status {rc}")
        time.sleep(2)
    fail(RC_GUEST, "timed out waiting for sshd remedy to finish")


# ----------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="vSphere stages of the validation harness")
    p.add_argument("--vcenter", required=True)
    p.add_argument("--template")
    p.add_argument("--name", help="name for the new VM (clone mode)")
    p.add_argument("--mode", choices=["clone", "convert"], default="clone")
    p.add_argument("--i-understand-this-destroys-the-template",
                   action="store_true", dest="confirm_destroy")
    p.add_argument("--folder", help="folder filter, e.g. Templates")
    p.add_argument("--portgroup")
    p.add_argument("--datastore")
    p.add_argument("--resource-pool")
    p.add_argument("--list-templates", action="store_true")
    p.add_argument("--list-name",
                   help="with --list-templates, show only this exact VM/template name")
    p.add_argument("--list-folders", action="store_true",
                   help="print the VM folder hierarchy to discover the real layout")
    p.add_argument("--finalize", metavar="VM_NAME",
                   help="power off VM_NAME and convert it back into a template")
    p.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (common for internal vCenters)")
    p.add_argument("--ip-timeout", type=int, default=300)
    p.add_argument("--no-power-on", action="store_true")
    p.add_argument("--guest-remedy-ssh", action="store_true",
                   help="fix sshd_config and start sshd via VMware Guest Operations")
    p.add_argument("--vm-name", help="target VM name for --guest-remedy-ssh")
    args = p.parse_args()

    # Validate destructive intent before opening a connection, so the run
    # fails immediately rather than after touching vCenter.
    if args.mode == "convert" and not args.confirm_destroy:
        fail(RC_USAGE,
             "--mode convert destroys the template. Re-run with "
             "--i-understand-this-destroys-the-template, or use the default "
             "--mode clone which leaves the template intact.")

    user = os.environ.get("VCENTER_USER")
    password = os.environ.get("VCENTER_PASSWORD")
    if not user or not password:
        fail(RC_USAGE,
             "set VCENTER_USER and VCENTER_PASSWORD in the environment "
             "(never pass credentials as command-line arguments)")

    si = connect_vcenter(args.vcenter, user, password, args.insecure)
    content = si.content

    if args.list_folders:
        list_folders(content, args.folder)
        return RC_OK

    if args.finalize:
        vm = finalize_as_template(content, args.finalize)
        print(json.dumps({"vm_name": args.finalize, "template": True,
                          "folder": folder_path(vm)}))
        return RC_OK

    if args.list_templates:
        list_templates(content, args.folder, args.list_name)
        return RC_OK

    if args.guest_remedy_ssh:
        vm_name = args.vm_name or args.name
        if not vm_name:
            fail(RC_USAGE, "--vm-name is required with --guest-remedy-ssh")
        guest_user = os.environ.get("TARGET_SSH_USER", "tpx-admin")
        guest_pass = os.environ.get("SSHPASS", "")
        if not guest_pass:
            fail(RC_USAGE, "set SSHPASS for guest SSH remedy")
        sudo_pass = os.environ.get("SUDO_PASSWORD") or guest_pass
        guest_remedy_ssh(content, vm_name, guest_user, guest_pass, sudo_pass)
        print(json.dumps({"vm_name": vm_name, "ssh_remedy": "applied"}))
        return RC_OK

    if not args.template:
        fail(RC_USAGE, "--template is required (or use --list-templates)")

    if args.mode == "convert":
        # A previous run may have converted the template and then failed before
        # restoring it. Reuse that VM instead of demanding manual cleanup.
        already = [o for o, p in bulk_fetch(content, content.rootFolder,
                                            vim.VirtualMachine,
                                            ["name", "config.template"])
                   if p.get("name") == args.template and not p.get("config.template")]
        if already:
            vm = already[0]
            path = folder_path(vm)
            enforce_scope(vm, path)
            log("2/8 TEMPLATE",
                f"'{args.template}' is already a virtual machine from an earlier "
                f"run - reusing it instead of converting again")
            connect_nic(content, vm, args.portgroup)
            ip = None if args.no_power_on else power_on_and_wait(vm, args.ip_timeout)
            print(json.dumps({
                "vm_name": vm.name, "ip": ip, "mode": args.mode,
                "template": args.template,
                "guest_os": vm.config.guestFullName if vm.config else None,
                "power_state": str(vm.runtime.powerState),
            }))
            return RC_OK

    template = find_template(content, args.template, args.folder)

    if args.mode == "convert":
        if not args.confirm_destroy:
            fail(RC_USAGE,
                 "--mode convert destroys the template. Re-run with "
                 "--i-understand-this-destroys-the-template, or use the default "
                 "--mode clone which leaves the template intact.")
        vm = convert_template(template)
    else:
        if not args.name:
            fail(RC_USAGE, "--name is required in clone mode")
        # Bulk fetch: reading .name per VM would be one round trip each.
        existing = bulk_fetch(content, content.rootFolder, vim.VirtualMachine, ["name"])
        if any(p.get("name") == args.name for _o, p in existing):
            fail(RC_CLONE, f"a VM named '{args.name}' already exists; pick another --name")
        vm = clone_template(content, template, args.name, args.datastore,
                            None, args.resource_pool, args.portgroup)

    connect_nic(content, vm, args.portgroup)

    ip = None if args.no_power_on else power_on_and_wait(vm, args.ip_timeout)

    print(json.dumps({
        "vm_name": vm.name,
        "ip": ip,
        "mode": args.mode,
        "template": args.template,
        "guest_os": vm.config.guestFullName if vm.config else None,
        "power_state": str(vm.runtime.powerState),
    }))
    return RC_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        fail(RC_USAGE, "interrupted")
