# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repo.

## Project Overview

Deploys an OKD-SCOS cluster onto a Proxmox VE cluster with Terraform. Topology
is configurable: 3-node compact (default), 3 control plane + N workers, or
Single Node OpenShift (`master_count=1`). After infra comes up, Terraform
invokes `cert-manager/scripts/apply.sh` to issue a Let's Encrypt wildcard cert
via DNS-01 against Azure DNS. Bring-up is idempotent: destroy and recreate at
any time and the cluster returns at the same `apps.<base_domain>` URL with a
valid TLS chain.

Masters are spread round-robin across hypervisors. The API and `*.apps` VIPs
are held by keepalived on the cluster nodes; there is no external load balancer.

Azure DNS is the one remaining cloud dependency — Proxmox has no DNS service,
and keeping the zone there leaves the cert-manager DNS-01 flow untouched.

The `main` branch still targets Azure. This branch replaces the whole Terraform
layer; do not port changes between them without checking which platform an
assumption belongs to.

The Ansible scaffolding from earlier iterations lives under `archive/` and is
not used.

## Prerequisites

- Terraform >= 1.5
- `kubectl`, `python3`, `curl`, `tar` on PATH
- Pull secret at `${HOME}/Downloads/pull-secret.txt` (override with
  `PULL_SECRET_FILE`)
- Proxmox API token created with `--privsep=0` (without it the token has no
  permissions regardless of the user's role)
- SSH access to every node in `proxmox_nodes` — snippet upload is the one
  operation the Proxmox REST API cannot perform, and API-token auth cannot
  derive an SSH credential from the token
- A `snippets`-enabled datastore, shared across nodes (CephFS; Ceph RBD cannot
  hold snippets), and likewise for the image datastore
- DHCP static mappings for the pinned MACs, plus two free addresses for the
  VIPs, and VRRP multicast permitted on the bridge
- Azure DNS public zone for `base_domain` (default zone resource group:
  `resources`) and a Service Principal with **DNS Zone Contributor** on it

`openshift-install` is fetched and kept up to date in `.bin/` by
`scripts/00-fetch-openshift-install.sh` — no manual install needed. It resolves
the newest stable release from `okd-project/okd` (NOT the retired
`okd-project/okd-scos` repo, which stopped publishing at 4.19 ec) by picking the
highest version tag rather than trusting GitHub's `releases/latest` flag, which
points at an older stable branch. It upgrades in place but never downgrades.

## Commands

### Full bring-up / teardown (preferred)

```bash
scripts/04-bringup.sh -auto-approve   # fetch tools, render configs, apply
scripts/05-teardown.sh -auto-approve  # terraform destroy
```

### Terraform directly (advanced)

```bash
cd terraform
terraform init
terraform fmt
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform destroy
```

`proxmox_endpoint`, `proxmox_api_token`, `proxmox_nodes`, `proxmox_datastore`,
`machine_network_cidr`, `api_vip`, `ingress_vip`, `scos_image_url`,
`ssh_public_key` and the four `cert_manager_azure_*` variables have no defaults
— set them in `terraform/terraform.tfvars` (see `terraform.tfvars.example`).

## Architecture

### Layout

- `terraform/` — image download, ignition snippets, VMs, public DNS,
  cert-manager apply trigger
- `lb/` — keepalived config templates and the VIP health-check loop
- `cert-manager/` — vendored cert-manager bundle + templated Issuer / Cert /
  IngressController + post-cluster apply script
- `install/` — `install-config.yaml.tpl` and the `openshift-install` workdir
  (`metadata.json`, `*.ign`, `auth/`); contents are gitignored
- `scripts/` — bootstrap (fetch tools, render config, render LB manifests,
  bringup, teardown)

### Topology (set in `terraform/terraform.tfvars`)

| `master_count` | `worker_count` | Mode | Bootstrap VM? | Router runs on |
|---:|---:|---|:---:|---|
| 3 | 0 | Compact (default) | yes | masters (HostNetwork) |
| 3 | N | HA + workers      | yes | workers (HostNetwork) |
| 1 | 0 | Single Node OpenShift | **no** (bootstrap-in-place) | the master |
| 1 | N | rejected by `check` block in `variables.tf` | — | — |

Per-role sizing: `{master,worker,bootstrap}_{cpu_cores,memory_mb,disk_gb}`.

### Why `platform: none`

`platform: baremetal` would render the on-prem networking stack for free
(keepalived + haproxy + coredns static pods), but its validation requires
`platform.baremetal.hosts` with BMC credentials, which Proxmox VMs do not have:

```
platform.baremetal.hosts: Required value: not enough hosts found (0)
to support all the configured ControlPlane replicas (3)
```

So the install uses `platform: none` and `lb/` supplies the VIPs. Two knock-on
effects worth knowing:

- Under `platform: none` the installer emits a DNS config with neither
  `publicZone` nor `privateZone`, so the cluster-ingress-operator cannot claim
  the `*.apps` records. The zone-stripping workaround the Azure branch needs
  (both pre-ignition and on the live cluster) is dead code here.
- There is no cloud controller manager, so nothing creates a
  LoadBalancer-type Service for ingress and nothing competes with Terraform
  over load balancer frontends.

### The VIP layer

`scripts/03-render-lb-manifests.sh` renders keepalived into two places, because
they are reached differently:

- **masters** — a MachineConfig written to `install/openshift/` between
  `create manifests` and `create ignition-configs`, so it ends up in the
  rendered master config that MCS serves on first boot
- **bootstrap** — patched directly into `bootstrap.ign` after generation.
  That file is a complete, self-contained config delivered locally via fw_cfg,
  so unlike `master.ign` it needs no network to apply

Priorities drive the handover with no manual step: healthy master 150, healthy
bootstrap 90, unhealthy master 50, unhealthy bootstrap 40. While the masters
have no API, bootstrap outranks them and serves `api-int:22623` so they can
fetch ignition; the moment a master's `/readyz` answers it takes the VIP.

Health is published as flag files by a host-side loop
(`lb/vip-healthcheck.sh`), and keepalived's check is reduced to `test -f`.
Probing from inside the keepalived container would depend on that image
shipping curl and a CA bundle; this way the container contract is nothing.

Deliberately **no HAProxy and no nftables**. OpenShift's on-prem stack DNATs
`VIP:6443` to a separate HAProxy port (`ocp_nat` table, `apiPort` != `lbPort`)
with `baremetal-runtimecfg` regenerating configs from live cluster state, all
to load balance the API across masters. `kube-apiserver` already binds
`0.0.0.0:6443`, so a VIP on a master is served directly. Trade-off: one master
takes all external API traffic at a time.

### Addressing

MACs are pinned by Terraform as `<prefix>:<role>:00:<index>` (role `00`
bootstrap, `01` master, `02` worker) so DHCP static mappings survive
destroy/recreate. `terraform output node_mac_addresses` prints them.

Static addressing inside the guest is not an option: `master.ign` is a pointer
config that merges from `api-int:22623`, so Ignition needs a working NIC during
its fetch stage — which runs before the files stage that would write a
NetworkManager keyfile. SCOS does static addressing with `ip=` kernel
arguments, and a disk-image boot leaves nowhere to inject those.

### Ignition delivery

Proxmox has no native Ignition support. Configs go through the QEMU
firmware-config device, read by CoreOS from `opt/com.coreos/config`.

The config could be inlined as `-fw_cfg name=...,string=<json>`, which is what
most guides do. That works for a ~2 KB pointer config and not at all for the
~320 KB `bootstrap.ign`, so every ignition is uploaded as a snippet and fw_cfg
points at the file. `proxmox_snippet_path` must match the snippets datastore:
`<storage path>/snippets`, i.e. `/mnt/pve/<storage-id>/snippets` for a mounted
store, `/var/lib/vz/snippets` only for the built-in `local`.

### Image

`proxmox_download_file` pulls the SCOS qemu artifact straight onto a node via
the PVE download-url API. SCOS publishes it gzipped, which forces
`content_type = "iso"` plus `decompression_algorithm`, and therefore
`disk.file_id` rather than `disk.import_from` — the provider only accepts
`import_from` for uncompressed images. Get the URL and checksum for a release
with `openshift-install coreos print-stream-json`; do not hand-pick a build.

### Bring-up control flow

`scripts/04-bringup.sh`:

1. Fetch or update `openshift-install` → `.bin/openshift-install`
2. `terraform init` (always; apply fails when `.terraform/providers` drifts
   from the lock file, and `state_count` needs an initialized backend)
3. If terraform state is empty *or* `master.ign` is missing → wipe `install/`
   artifacts and regenerate: render install-config, `create manifests`, render
   the keepalived MachineConfig, `create ignition-configs`, patch
   `bootstrap.ign` (or `create single-node-ignition-config` for SNO)
4. `terraform apply` (passing through any extra args)

`cert-manager/scripts/apply.sh` runs from a `null_resource` in
`terraform/cert_manager.tf` once the API is reachable. It waits for the
`kube-apiserver` clusteroperator to *exist* before waiting for it to be
Available — `kubectl wait` exits immediately with NotFound on a missing
resource, and on a fresh bringup the /healthz gate above it is satisfied by the
bootstrap node's temporary control plane long before the CVO has created any
ClusterOperators.

## Conventions

- All Proxmox resource names are prefixed with the install-time infraID
  (extracted from `install/metadata.json`)
- Secrets (Proxmox API token, Azure SP client secret, ssh public key) flow only
  through `terraform/terraform.tfvars` (gitignored) — never logged or echoed
- After any change touching `terraform/`, run `terraform fmt && terraform
  validate` before claiming work is done
