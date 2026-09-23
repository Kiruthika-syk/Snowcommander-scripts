# Snow Commander — RHEL Security Tools

Template validation and fleet deployment for Tanium, CrowdStrike, Azure Arc (Sentinel), cmdbsync, and rsyslog on RHEL templates across FW, BLR, and STC vCenters.

## Documentation

Full guide (setup, encrypted credentials, execution methodology, vCenter reference):

- **Website:** [docs/index.html](docs/index.html) — serve locally or via the docs container on port 8080
- **PDF:** [docs/guide.pdf](docs/guide.pdf) — regenerate with `docs/build-guide-pdf.sh` after editing the HTML

## Quick start (jump host)

```bash
cd /home/tpx-admin/snowcommander_scripts
git pull

cp credentials.env.example ~/.snowcommander-creds.env
chmod 600 ~/.snowcommander-creds.env
# Edit VCENTER_*, SSHPASS, FALCON_CID, AZCM_*, RHSM_*, …

./scripts/creds-vault.sh init
./scripts/creds-vault.sh encrypt

./target.sh list
./target.sh e2e-stc --template-cycle --insecure   # STC SC-Redhat 9
```

`target.sh` auto-decrypts `~/.snowcommander-creds.env.vault` — no password prompt at runtime.

## Other sites

```bash
./target.sh e2e fw FW-GI-7.3 --template-cycle --insecure
./target.sh e2e blr BLR-Redhat-9 --template-cycle --insecure
./target.sh e2e stc 'SC-GI 7.1' --template-cycle --insecure   # if in SnowComander/Templates
```

## Fleet deploy (after templates validated)

```bash
./target.sh write-inventory ./inventory
./target.sh container deploy
```

## Repo layout

| Path | Purpose |
|------|---------|
| `target.sh` | Entry point — e2e, catalogue, fleet deploy |
| `security.sh` | Install/verify on target |
| `uninstall.sh` | Remove agents (stage 7) |
| `scripts/e2e_validate.sh` | 8-stage vSphere validation harness |
| `scripts/creds-vault.sh` | Encrypt credentials with ansible-vault |
| `docs/index.html` | Full operator guide |

Vendor RPMs (~548 MB) are **not** in git — stage from `/opt/snowcommander-packages/`.
