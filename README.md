# OKD on Proxmox VE with Terraform

3-node compact OKD-SCOS cluster on a Proxmox VE cluster (masters schedulable as
workers), provisioned via Terraform with a Let's Encrypt wildcard cert managed
by cert-manager. The bring-up is idempotent: destroy and recreate at any time
and the cluster comes back at the same `apps.<base_domain>` URL with a valid
TLS chain.

Masters are spread across hypervisors, so losing one Proxmox node does not take
the control plane with it. The API and `*.apps` VIPs are held by keepalived
running on the nodes themselves — there is no external load balancer to
maintain.

> DNS stays on Azure DNS. Proxmox has no DNS service, and keeping the zone
> there means the cert-manager DNS-01 flow works unchanged. It is the only
> cloud dependency left.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.5
- `kubectl`, `python3`, `curl`, `tar` on PATH
- A pull secret at `${HOME}/Downloads/pull-secret.txt` (override via
  `PULL_SECRET_FILE`). Get one from
  <https://console.redhat.com/openshift/install/pull-secret>.
- Azure DNS public zone hosting the cluster's base domain, plus a service
  principal with **DNS Zone Contributor** on it (cert-manager DNS-01)

### On Proxmox

- An API token. Create it with:

  ```bash
  pveum user add terraform@pve
  pveum role add Terraform -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU \
    VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory \
    VM.Config.Network VM.Config.Options VM.Monitor VM.Audit VM.PowerMgmt \
    Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate \
    Datastore.Audit Sys.Audit Sys.Modify Sys.Console"
  pveum aclmod / -user terraform@pve -role Terraform
  pveum user token add terraform@pve provider --privsep=0
  ```

  `--privsep=0` is not optional: with privilege separation on, the token gets
  no permissions regardless of the user's role and every call 403s.

- **SSH access to every node in `proxmox_nodes`.** Uploading a snippet is the
  one thing the Proxmox REST API cannot do, so the provider falls back to SSH —
  and with API-token auth it cannot derive an SSH credential from the token.
  Point `proxmox_ssh_private_key_file` at a key that works, or set
  `proxmox_ssh_agent = true` with the key loaded.

- A datastore with the **`snippets`** content type enabled (off by default;
  Datacenter → Storage). When `proxmox_nodes` has more than one entry it must
  also be **shared**, because the ignition files are uploaded once through the
  first node and read by whichever node ends up running the VM. CephFS works;
  Ceph RBD cannot hold snippets at all, only CephFS can.

- The same shared requirement applies to the datastore holding the SCOS image.

### On the network

- A DHCP server with **static mappings** for the MACs Terraform pins (see
  [Addressing](#addressing)), at addresses outside its dynamic pool
- Two further free addresses, mapped to nothing, for the API and ingress VIPs
- VRRP (multicast) permitted on the bridge. If the switch or firewall filters
  it, every node believes it owns the VIP.

## Structure

- `terraform/` — VMs, image download, ignition snippets, public DNS,
  cert-manager trigger
- `lb/` — keepalived config templates and the VIP health-check loop
- `cert-manager/` — vendored cert-manager bundle, templated Issuer / Cert /
  IngressController, post-cluster apply script
- `install/` — `install-config.yaml.tpl` and the `openshift-install` workdir
  (`metadata.json`, `*.ign`, `auth/`); contents are gitignored
- `scripts/` — bring-up / teardown wrappers

## Usage

### Bring up the cluster

```bash
scripts/04-bringup.sh -auto-approve
```

This script:

1. Fetches or updates `openshift-install` in `.bin/`
   (via `scripts/00-fetch-openshift-install.sh`). It installs the newest
   stable release from
   [okd-project/okd](https://github.com/okd-project/okd/releases) and upgrades
   an existing binary when a newer one ships. It never downgrades. Overrides:
   `OKD_VERSION=4.x.y-okd-scos.N` pins an exact release,
   `OKD_SKIP_UPDATE_CHECK=1` keeps the current binary offline, and
   `OKD_ALLOW_PRERELEASE=1` also considers `ec` builds
2. Runs `terraform init`, then detects whether terraform state is empty
   (fresh checkout or post-destroy)
3. If so, wipes stale `install/` artifacts and regenerates them — a fresh
   infraID and a fresh 24h MCS bootstrap token. Between `create manifests` and
   `create ignition-configs` it renders the keepalived MachineConfig into
   `install/openshift/`, then patches `bootstrap.ign` afterwards
4. Runs `terraform apply`, which downloads the SCOS image, uploads the
   ignitions as snippets, creates the VMs, and then triggers
   `cert-manager/scripts/apply.sh` to install cert-manager, issue the wildcard
   cert via DNS-01, and patch the IngressController to serve it

If state is non-empty the script skips ignition regen and just re-applies, so
running it against a healthy cluster is a safe no-op.

### Tear down

```bash
scripts/05-teardown.sh -auto-approve
```

Just calls `terraform destroy`. The next `04-bringup.sh` regenerates ignitions
automatically.

### After bring-up

```bash
export KUBECONFIG=$PWD/install/auth/kubeconfig
oc whoami --show-console
cat install/auth/kubeadmin-password
```

Console: `https://console-openshift-console.apps.okd.<base_domain>`

## Topology

| `master_count` | `worker_count` | Mode | Bootstrap VM? | Router runs on |
|---:|---:|---|:---:|---|
| 3 | 0 | Compact (default) | yes | masters (HostNetwork) |
| 3 | N | HA + workers      | yes | workers (HostNetwork) |
| 1 | 0 | Single Node OpenShift | **no** (bootstrap-in-place) | the master |
| 1 | N | (rejected) | — | — |

Per-role sizing: `master_cpu_cores` / `master_memory_mb` / `master_disk_gb`,
and the `worker_*` and `bootstrap_*` equivalents.

Masters and workers are placed round-robin across `proxmox_nodes`. Check the
result before applying with `terraform output node_placement`.

SNO note: `master_count=1` triggers `openshift-install create
single-node-ignition-config`, and `bootstrapInPlace.installationDisk` is
`/dev/vda` — Proxmox attaches the root disk as virtio0, so the `/dev/sda` an
Azure deployment would use does not exist in the guest.

## Addressing

Terraform pins each VM's MAC so DHCP static mappings can be created once and
survive destroy/recreate. The layout is `<prefix>:<role>:00:<index>`, with role
`00` bootstrap, `01` master, `02` worker — so with the default prefix:

| MAC | Node |
|---|---|
| `02:00:00:00:00:00` | bootstrap |
| `02:00:00:01:00:00` | master-0 |
| `02:00:00:01:00:01` | master-1 |
| `02:00:00:01:00:02` | master-2 |

`terraform output node_mac_addresses` prints them for the current topology.

**Why DHCP rather than static addresses in the guest.** `master.ign` is a ~2 KB
Ignition *pointer* config whose only job is to merge the real config from
`https://api-int.<domain>:22623`. Ignition therefore needs a working NIC during
its fetch stage, which runs before the files stage that would write any
NetworkManager keyfile. Static addressing on SCOS is normally done with `ip=`
kernel arguments, and booting from a disk image leaves nowhere to inject those
without rebuilding the image. A static DHCP mapping gives the same fixed
address with none of that.

## The VIPs

`platform: none` renders no on-prem load balancer — that is a `baremetal`
platform feature, and `baremetal` requires `platform.baremetal.hosts` with BMC
credentials that Proxmox VMs do not have. `lb/` fills the gap with keepalived.

Priorities make the bootstrap handover automatic:

| | Priority |
|---|---|
| healthy master | 150 |
| healthy bootstrap | 90 |
| unhealthy master | 50 |
| unhealthy bootstrap | 40 |

While the masters have no API of their own, bootstrap outranks them and serves
`api-int:22623` so they can fetch their ignition. As soon as a master's
`/readyz` answers it outranks bootstrap and takes the VIP; destroying the
bootstrap VM then requires no further action.

The ingress VIP is a separate VRRP group whose health check requires a local
router to answer on `:1936`, so it only ever lands on a node actually running
one.

There is deliberately **no HAProxy and no nftables**. OpenShift's own on-prem
stack DNATs `VIP:6443` to a separate HAProxy port and has
`baremetal-runtimecfg` regenerate both configs from live cluster state, all to
load balance the API across masters. `kube-apiserver` already binds
`0.0.0.0:6443`, so a VIP landing on a master is served directly. The trade-off
is that one master handles all external API traffic at a time; VRRP failover
still covers node loss.

If the VIPs never come up, in order: `podman logs okd-keepalived` on a node,
then confirm `vrrp_interface` matches what `ip link` reports (the default
`ens18` is right for a virtio NIC but is not guaranteed), then check that VRRP
multicast is not being filtered.

## Ignition delivery

Proxmox has no native Ignition support, so configs are passed through the QEMU
firmware-config device, which CoreOS reads from `opt/com.coreos/config`.

Most guides pass the config inline as `-fw_cfg name=...,string=<json>`. That is
fine for a 2 KB pointer config and impossible for the ~320 KB `bootstrap.ign`,
so each ignition is uploaded as a snippet and fw_cfg points at the file
instead. `proxmox_snippet_path` must therefore match the snippets datastore:
`<storage path>/snippets`, which is `/mnt/pve/<storage-id>/snippets` for any
mounted store and only `/var/lib/vz/snippets` for the built-in `local` one.
Confirm with `pvesh get /storage/<id>`.

## Variables

See `terraform/variables.tf` for all inputs, and
`terraform/terraform.tfvars.example` for a working starting point. The
sensitive ones are `proxmox_api_token` and `cert_manager_azure_client_secret`,
both supplied via `terraform/terraform.tfvars` (gitignored).
