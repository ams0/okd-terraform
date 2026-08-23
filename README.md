# OKD on Azure UPI with Terraform

3-node compact OKD-SCOS cluster on Azure (masters schedulable as workers),
provisioned via Terraform with Let's Encrypt wildcard cert managed by
cert-manager. The bring-up is fully idempotent: destroy and recreate at any
time and the cluster comes back up with the same `apps.<base_domain>` URL and a
valid TLS chain.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in via `az login`)
- `kubectl` and `python3` on PATH
- A pull secret at `${HOME}/Downloads/pull-secret.txt` (override via `PULL_SECRET_FILE` env var). Get one from <https://console.redhat.com/openshift/install/pull-secret>.
- A persistent storage account holding the SCOS VHD blob (set `scos_vhd_blob_uri` in `terraform/terraform.tfvars`)
- Azure DNS public zone hosting the cluster's base domain
- Service principal with DNS Zone Contributor on that zone (for cert-manager DNS-01)

## Structure

- `terraform/` — Terraform stack: networking, LBs, VMs, public + private DNS, cert-manager apply, IngressController switch
- `cert-manager/` — Static cert-manager bundle, templated Issuer/Cert/IngressController, post-cluster apply script
- `install/` — `install-config.yaml.tpl` and openshift-install workdir (`metadata.json`, `*.ign`, `auth/`)
- `scripts/` — Bring-up / teardown wrappers

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
3. If so, wipes stale `install/` artifacts and regenerates them via
   `openshift-install create manifests + ignition-configs` — this produces a
   fresh infraID and a fresh 24h MCS bootstrap token
4. Runs `terraform apply`, which after infra is up triggers
   `cert-manager/scripts/apply.sh` to:
   - Wait for kube-apiserver to be Available
   - Install cert-manager + patch its DNS resolvers
   - Switch the default IngressController to `HostNetwork` (router pods bind
     master :80/:443 directly, matching the pre-created LB rules and NSG)
   - Issue a Let's Encrypt wildcard cert via DNS-01 against Azure DNS
   - Patch the IngressController to serve that cert

If state is non-empty the script skips ignition regen and just re-applies — so
running it on a healthy cluster is a safe no-op.

### Tear down

```bash
scripts/05-teardown.sh -auto-approve
```

Just calls `terraform destroy`. The next `04-bringup.sh` will regenerate
ignitions automatically.

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

VM sizes per role: `master_vm_size`, `worker_vm_size`, `bootstrap_vm_size`.

SNO note: `master_count=1` triggers `openshift-install create
single-node-ignition-config` (instead of the usual `create manifests` +
`create ignition-configs`). The single-node ignition is uploaded to blob
storage and the master VM consumes it via the same SAS-stub pattern used by
the bootstrap VM in HA mode. `bootstrapInPlace.installationDisk` is set to
`/dev/sda` (the SCOS managed-image OS disk path on Azure).

## Variables

See `terraform/variables.tf` for all inputs. The two sensitive ones are
`cert_manager_azure_client_secret` (DNS Zone Contributor SP) and
`ssh_public_key` — both supplied via `terraform/terraform.tfvars`.
