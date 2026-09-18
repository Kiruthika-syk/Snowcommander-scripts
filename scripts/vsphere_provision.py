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
import json
import os
import ssl
import sys
import time

from pyVim import connect
from pyVmomi import vim

RC_OK, RC_USAGE, RC_CONNECT, RC_NOTFOUND, RC_CLONE, RC_POWER = 0, 2, 3, 4, 5, 6


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


def get_all(content, vimtype):
    view = content.viewManager.CreateContainerView(content.rootFolder, [vimtype], True)
    try:
        return list(view.view)
    finally:
        view.Destroy()


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
def list_templates(content, folder_filter: str | None) -> None:
    log("2/8 TEMPLATE", "enumerating templates")
    rows = []
    for vm in get_all(content, vim.VirtualMachine):
        try:
            if not (vm.config and vm.config.template):
                continue
            path = folder_path(vm)
            if folder_filter and folder_filter.lower() not in path.lower():
                continue
            rows.append((vm.name, vm.config.guestFullName or "unknown", path))
        except Exception:  # noqa: BLE001
            continue

    if not rows:
        log("2/8 TEMPLATE", "no templates matched")
        return

    print(f"{'TEMPLATE':<34} {'GUEST OS':<44} FOLDER", file=sys.stderr)
    print("-" * 110, file=sys.stderr)
    for name, guest, path in sorted(rows):
        print(f"{name:<34} {guest:<44} {path}", file=sys.stderr)
    log("2/8 TEMPLATE", f"{len(rows)} template(s)")


def find_template(content, name: str, folder_filter: str | None):
    log("2/8 TEMPLATE", f"searching for template '{name}'")
    matches = []
    for vm in get_all(content, vim.VirtualMachine):
        if vm.name != name:
            continue
        if not (vm.config and vm.config.template):
            fail(RC_NOTFOUND, f"'{name}' exists but is a VM, not a template")
        if folder_filter and folder_filter.lower() not in folder_path(vm).lower():
            continue
        matches.append(vm)

    if not matches:
        fail(RC_NOTFOUND,
             f"template '{name}' not found; run --list-templates to see what exists")
    if len(matches) > 1:
        fail(RC_NOTFOUND,
             f"'{name}' is ambiguous ({len(matches)} matches); narrow it with --folder")

    vm = matches[0]
    log("2/8 TEMPLATE",
        f"found: {vm.name} | guest={vm.config.guestFullName} | folder={folder_path(vm)}")
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
    p.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (common for internal vCenters)")
    p.add_argument("--ip-timeout", type=int, default=300)
    p.add_argument("--no-power-on", action="store_true")
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

    if args.list_templates:
        list_templates(content, args.folder)
        return RC_OK

    if not args.template:
        fail(RC_USAGE, "--template is required (or use --list-templates)")

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
        if any(v.name == args.name for v in get_all(content, vim.VirtualMachine)):
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
