# Port OKD bring-up from Azure to Proxmox VE

Branch: `proxmox`. Target: same guarantees as the Azure path — idempotent
destroy/recreate, cluster returns at the same `apps.<base_domain>` URL with a
valid Let's Encrypt chain.

## Decisions (settled 2026-08-24)

| Area | Choice | Why |
|---|---|---|
| Platform | `platform: none` | `baremetal` requires BMC hosts; Proxmox VMs have none (verified) |
| API + ingress VIP | keepalived + HAProxy static pods via MachineConfig | Self-contained, no extra VM, no SPOF |
| Node addressing | DHCP **with reservations** (TF pins MACs) | Static pod backend lists need stable control-plane IPs |
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

- [ ] Proxmox API token **and** SSH access (snippet upload uses SSH, not the API)
- [ ] Snippets enabled on the target datastore (Datacenter → Storage; off by default)
- [ ] `Datastore.AllocateTemplate`, `Sys.Audit`, `Sys.Modify` for image download
- [ ] Two free IPs on the node subnet for the API and ingress VIPs
- [ ] DHCP reservations for the MACs Terraform assigns
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

## Phase 4 — On-node load balancing

- [ ] Butane/MachineConfig: keepalived (VRRP, both VIPs) + HAProxy static pods
- [ ] Drop into `install/openshift/` as `99-*` manifests before ignitions bake
- [ ] Health checks so the ingress VIP only lands on nodes running a router

## Phase 5 — DNS and cert-manager

- [x] `dns_public.tf`: keep, repoint `api` / `*.apps` A records at the VIPs
- [x] Delete `dns_private.tf`
- [ ] `cert_manager.tf` + `apply.sh`: drop the CCM/HostNetwork switch and the
      zone-stripping patch; verify the default IngressController strategy under
      `platform: none`

## Phase 6 — Scripts and docs

- [ ] `02-render-install-config.sh`: emit `platform: none` + machineNetwork;
      drop Azure fields
- [ ] `04-bringup.sh`: drop the DNS-stripping step; keep state/regen logic
- [x] Delete `lb.tf`, `storage.tf`, `network.tf`, `dns_private.tf`
- [ ] Rewrite `CLAUDE.md` + `README.md` for Proxmox

## Open risks

- keepalived/HAProxy static pods are the piece OKD normally generates via
  `runtimecfg`. Ours are hand-rolled, so VIP failover and the bootstrap
  ordering (VIP must exist before the API does) need real testing.
- SCOS qcow2 must boot under the chosen machine type / firmware; may need
  `q35` + UEFI vs `pc` + SeaBIOS. Verify on first VM.
- `openshift-install` still needs `install-config.yaml` to satisfy
  `platform: none` validation for SNO as well — re-run the spike for
  `master_count = 1`.

## Review

_(fill in as phases land)_
