# 2026 Snow Commander security-tools template

Combined local installer for RHEL 9 and RHEL 10 templates.

## Included

- Tanium Client `7.8.4.1298`
  - RHEL 9/10
  - `x86_64` and `aarch64`
  - sourced only from `/tmp/linux-client-bundle 7.8.4.1298.zip`
- CrowdStrike Falcon `8.10.0-19402`
  - EL 7/8/9/10
  - `x86_64` (all) and `aarch64` (EL 8/9/10 only — no el7 aarch64 sensor is published)
  - selected automatically by detected OS/architecture; no version is hardcoded
- `cmdbsync` account and validated sudoers policy
- Sentinel / Azure Arc installer
- rsyslog forwarding

## Run

```bash
cd /home/tpx-admin/securitytools/2026snowcommander
./install_security_tools.sh all
```

As `tpx-admin`, the script auto-runs `sudo -S` using `SSHPASS`, `PORTAL_SUDO_PASSWORD`, or
`/home/tpx-admin/crowdstrike/.ssh_credentials` — no manual `sudo su -` needed.

Individual tools:

```bash
sudo ./install_security_tools.sh tanium
sudo ./install_security_tools.sh crowdstrike
sudo ./install_security_tools.sh cmdbsync
sudo ./install_security_tools.sh sentinel
sudo ./install_security_tools.sh syslog
```

Verification only:

```bash
sudo ./install_security_tools.sh verify
```

## Configuration

Runtime credentials are in `securitytools.env` (mode `600`) rather than embedded
in the installer. `securitytools.env.example` documents all required values.

## Log

```text
/var/log/securitytools-template-install.log
```

The combined run continues to later components if one component fails, prints a
final pass/fail summary, and returns non-zero if any component failed.
