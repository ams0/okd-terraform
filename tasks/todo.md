# Port OKD bring-up from Azure to Proxmox VE

Branch: `proxmox`. Target: same guarantees as the Azure path — idempotent
destroy/recreate, cluster returns at the same `apps.<base_domain>` URL with a
valid Let's Encrypt chain.

## Decisions (settled 2026-08-24)

| Area | Choice | Why |
|---|---|---|
| Platform | `platform: none` | `baremetal` requires BMC hosts; Proxmox VMs have none (verified) |
| API + ingress VIP | keepalived + HAProxy static pods via MachineConfig | Self-contained, no extra VM, no SPOF |
| Node addressing | OPNsense **static DHCP mappings** to fixed IPs outside the pool (TF pins MACs) | In-guest static config is impossible: Ignition fetches its real config from api-int:22623 *before* it writes any file it could configure the NIC with |
| Public DNS | Stays on Azure DNS | cert-manager DNS-01 + wildcard cert flow carry over untouched |
| Private/split DNS | Dropped | `platform: none` renders no `publicZone`/`privateZone` (verified) |
| TF provider | `bpg/proxmox` | Actively maintained; PVE 9.x support |
| SCOS image | `proxmox_download_file` | Pulls qcow2 directly onto the node via PVE `download-url` |
| Ignition delivery | fw_cfg pointing at an uploaded **snippet** | `master.ign` is far too large for an inline `string=` on the QEMU cmdline |

## Verified spikes

- [x] `platform: baremetal` + no hosts → rejected: `platform.baremetal.hosts:
      Required value: not enough hosts found (0)`
- [x] `platform: none` → renders 14 manifests, masters auto-schedulable
- [x] `platform: none` → `cluster-dns-02-config.yml` has no zones, so the
      zone-stripping workaround is dead code on this branch
- [x] `bpg` supports `kvm_arguments`, `content_type = "snippets"` (SSH-based),
      and `proxmox_download_file`

## Prerequisites for the operator (document in README)

- [x] Proxmox API token created (terraform@pve!provider)
- [x] SSH key wired (~/.ssh/fromvolt, ed25519) — verified into pve1/2/3 as root,
      /mnt/pve/cephfs/snippets writable on each, and a file written via pve1 reads
      back identically from pve2 and pve3 (the shared-storage premise spreading needs)
- [x] Snippets enabled on the target datastore — already on for `cephfs` (content: snippets,backup,import,iso,vztmpl; shared:1; path /mnt/pve/cephfs)
- [ ] `Datastore.AllocateTemplate`, `Sys.Audit`, `Sys.Modify` for image download
- [x] ~~`Import` content type~~ — not needed; SCOS ships gzipped so the image uses `iso` + `decompression_algorithm`
- [x] VIPs chosen: 192.168.228.50 (api) / .51 (ingress), outside the .100-.200 pool
- [x] OPNsense (Dnsmasq) static mappings created for .52-.55 — bootstrap plus
      three masters. Kea is disabled on that box; Dnsmasq serves DHCP
- [ ] Proxmox service account + API token (`--privsep=0`) and an SSH key for
      snippet upload
- [ ] Azure SP with DNS Zone Contributor (unchanged, for cert-manager)

## Phase 1 — Scaffolding

- [x] `providers.tf`: swap azurerm → bpg/proxmox, keep random/null/local
- [x] `variables.tf`: Proxmox connection, node/datastore/bridge, VIPs, per-role
      sizing; drop all Azure vars
- [x] `terraform.tfvars.example`: rewrite
- [x] `main.tf`: keep the metadata/infra_id/single_node/ignition locals; drop
      Azure tagging and the resource group

## Phase 2 — Image and ignition plumbing

- [x] `image.tf`: `proxmox_download_file` for the SCOS qcow2 (URL + checksum vars)
- [x] `ignition.tf`: upload `bootstrap.ign` / `master.ign` / `worker.ign` as
      snippets via `proxmox_virtual_environment_file`
- [x] Wire `kvm_arguments = "-fw_cfg name=opt/com.coreos/config,file=<snippet>"`

## Phase 3 — VMs

- [x] `vms.tf`: rewrite for `proxmox_virtual_environment_vm` (bootstrap,
      masters, workers), pinned MACs, disk cloned from the downloaded image
- [x] Preserve the SNO branch (bootstrap-in-place, no bootstrap VM)

## Verified end-to-end so far

- [x] `terraform plan` succeeds: 16 to add, 0 to change, 0 to destroy
- [x] Masters land on pve1/pve2/pve3 (one per hypervisor)
- [x] Pinned MACs match the OPNsense static mappings

**Do not apply yet.** The ignitions in `install/` are the stale Azure ones
(`platform: azure`); VMs built from them would boot and fail to bootstrap.
Phase 6 has to land first.

## Phase 4 — On-node load balancing  (done, untested on hardware)

- [x] keepalived via MachineConfig `99-master-okd-keepalived` into `install/openshift/`
- [x] bootstrap.ign patched directly (it is a complete config, not a pointer)
- [x] Health checks: ingress VIP only lands on a node whose router answers :1936
- [x] **No HAProxy, no nftables.** OpenShift's on-prem stack DNATs VIP:6443 to a
      separate haproxy port (`ocp_nat` table, `apiPort` != `lbPort`) purely to
      load balance the API across masters, with baremetal-runtimecfg
      regenerating both configs from live cluster state. kube-apiserver already
      binds 0.0.0.0:6443, so a VIP landing on a master is served directly.
      Trade-off accepted: one master serves all external API traffic at a time;
      VRRP failover still works.

## Phase 5 — DNS and cert-manager

- [x] `dns_public.tf`: keep, repoint `api` / `*.apps` A records at the VIPs
- [x] Delete `dns_private.tf`
- [ ] `cert_manager.tf` + `apply.sh`: drop the CCM/HostNetwork switch and the
      zone-stripping patch; verify the default IngressController strategy under
      `platform: none`

## Phase 6 — Scripts and docs

- [x] `02-render-install-config.sh`: emits `platform: none` + machineNetwork;
      Azure fields gone; SNO installationDisk fixed to /dev/vda (virtio, not sda)
- [x] `04-bringup.sh`: DNS-stripping step removed; renders the LB layer before
      ignitions bake and patches bootstrap.ign after
- [x] Delete `lb.tf`, `storage.tf`, `network.tf`, `dns_private.tf`
- [ ] Rewrite `CLAUDE.md` + `README.md` for Proxmox

## Why not true in-guest static IPs

`master.ign` is a 2 KB Ignition *pointer* config:

    config.merge.source = https://api-int.<domain>:22623/config/master

Ignition therefore needs a working NIC during its **fetch** stage, which runs
before the **files** stage that would write any NetworkManager keyfile. A
static address delivered through Ignition cannot be in effect when Ignition
needs the network, so RHCOS/SCOS static addressing is normally done with `ip=`
kernel arguments in the initramfs. Booting from a disk image on Proxmox gives
us nowhere to inject those without rebuilding the image's bootloader.

Static DHCP mappings give the same outcome — fixed, known addresses outside
the dynamic pool — with no image surgery.

## Open risks

- The VIP layer is hand-rolled and has never run on hardware. Specific things
  to watch on first bringup:
  - keepalived's `enable_script_security` may reject `/bin/sh -c 'test -f ...'`;
    if the VIPs never come up, check `podman logs okd-keepalived` first.
  - `vrrp_interface` defaults to ens18. Confirm with `ip link` on a booted node;
    a wrong name means keepalived starts but never claims the VIP.
  - Bootstrap->master handover depends only on priority (40+50 vs 50+100), so
    a master whose /readyz answers takes the VIP automatically. Verify the
    window where bootstrap's temporary control plane stops but the VM still
    exists does not strand the VIP.
  - VRRP needs multicast on the bridge. If OPNsense or the switch filters it,
    both nodes will think they own the VIP.
- SCOS qcow2 must boot under the chosen machine type / firmware; may need
  `q35` + UEFI vs `pc` + SeaBIOS. Verify on first VM.
- `openshift-install` still needs `install-config.yaml` to satisfy
  `platform: none` validation for SNO as well — re-run the spike for
  `master_count = 1`.

## Review

_(fill in as phases land)_
