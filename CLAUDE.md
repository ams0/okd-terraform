# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repo.

## Project Overview

Deploys an OKD-SCOS cluster on Azure UPI with Terraform. Topology is
configurable: 3-node compact (default), 3 control plane + N workers, or Single
Node OpenShift (`master_count=1`). After infra comes up, Terraform invokes
`cert-manager/scripts/apply.sh` to switch the default IngressController to
`HostNetwork` and issue a Let's Encrypt wildcard cert via DNS-01 against Azure
DNS. Bring-up is idempotent: destroy and recreate at any time and the cluster
returns at the same `apps.<base_domain>` URL with a valid TLS chain.

The Ansible scaffolding from earlier iterations now lives under `archive/` and
is not used.

## Prerequisites

- Terraform >= 1.0
- Azure CLI logged in (`az login`)
- `kubectl`, `python3`, `curl`, `tar` on PATH
- Pull secret at `${HOME}/Downloads/pull-secret.txt` (override with
  `PULL_SECRET_FILE`)
- A pre-uploaded SCOS VHD page blob (referenced by
  `scos_vhd_blob_uri` in `terraform/terraform.tfvars`)
- Azure DNS public zone for `base_domain` (default zone resource group:
  `resources`)
- Service Principal with **DNS Zone Contributor** on that zone (cert-manager
  DNS-01 solver)

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

`ssh_public_key`, `scos_vhd_blob_uri`, and the four `cert_manager_azure_*`
variables have no defaults — set them in `terraform/terraform.tfvars` (see
`terraform/terraform.tfvars.example`).

## Architecture

### Layout

- `terraform/` — networking, LBs, VMs, public + private DNS zones, cert-manager
  apply trigger, IngressController switch
- `cert-manager/` — vendored cert-manager bundle + templated Issuer / Cert /
  IngressController + post-cluster apply script
- `install/` — `install-config.yaml.tpl` and the `openshift-install` workdir
  (`metadata.json`, `*.ign`, `auth/`); contents are gitignored
- `scripts/` — bootstrap (fetch tools, render config, bringup, teardown,
  optional web-terminal install)

### Topology (set in `terraform/terraform.tfvars`)

| `master_count` | `worker_count` | Mode | Bootstrap VM? | Router runs on |
|---:|---:|---|:---:|---|
| 3 | 0 | Compact (default) | yes | masters (HostNetwork) |
| 3 | N | HA + workers      | yes | workers (HostNetwork) |
| 1 | 0 | Single Node OpenShift | **no** (bootstrap-in-place) | the master |
| 1 | N | rejected by `check` block in `variables.tf` | — | — |

Per-role VM sizes: `master_vm_size`, `worker_vm_size`, `bootstrap_vm_size`.

### Networking

- Single VNet `10.0.0.0/16`
- Master subnet `10.0.1.0/24`, worker subnet `10.0.2.0/24`
- Two Standard SKU LBs with static public IPs — one for the API, one for
  ingress / `*.apps`
- VMs have no public IPs; access goes through the LBs (or SSH via a bastion
  the user provisions separately)
- TF-managed `azurerm_lb.external` uses `lifecycle { ignore_changes =
  [frontend_ip_configuration] }` so the in-cluster Azure cloud-controller-manager
  can attach its own LoadBalancer Service frontends without TF fighting it

### DNS

- Public zone (Azure DNS) hosts `api.okd.<base_domain>`,
  `*.apps.okd.<base_domain>`, etc., pointing at the LB public IPs
- Private zone with the same name shadows the public one inside the VNet, so
  `*.apps` is duplicated there pointing at master IPs (or worker IPs when
  `worker_count > 0`). Without this, in-cluster DNS lookups for
  `console-openshift-console.apps.<…>` return NXDOMAIN, breaking console login
- `cluster-dns-02-config.yml` has its `publicZone` / `privateZone` fields
  cleared in `manifests/` *before* ignitions are baked, and again on the live
  cluster from `cert-manager/scripts/apply.sh`. This stops cluster-ingress-operator
  from claiming ownership of `*.apps` records and deleting the TF-managed ones
  whenever the IngressController is recreated

### Ignitions and the SAS-stub pattern

Azure VM `custom_data` has a 64 KB hard limit. `master.ign` (and the SNO
ignition) routinely exceed that. The pattern:

1. The full ignition is uploaded to a blob in the cluster's storage account
2. A short ignition stub (the "SAS stub") is generated, containing only
   a `replace` reference with a short-lived SAS URL
3. That stub is what goes into `custom_data`

This is implemented in `terraform/storage.tf` and `terraform/vms.tf`.

### Bring-up control flow

`scripts/04-bringup.sh`:

1. Fetch or update `openshift-install` → `.bin/openshift-install`
2. `terraform init` (always; apply fails when `.terraform/providers` drifts
   from the lock file, and `state_count` needs an initialized backend)
3. If terraform state is empty *or* `master.ign` is missing → wipe `install/`
   artifacts and regenerate (`create manifests` + `create ignition-configs`,
   or `create single-node-ignition-config` for SNO)
4. For HA mode: strip `publicZone` / `privateZone` from
   `install/manifests/cluster-dns-02-config.yml` before baking ignitions
5. `terraform apply` (passing through any extra args)

`cert-manager/scripts/apply.sh` runs from a `null_resource` in
`terraform/cert_manager.tf` once the API is reachable. It waits for
`kube-apiserver` only (not all clusteroperators — auth/console are
intentionally degraded until the IngressController is finalized), installs
cert-manager, creates the ClusterIssuer + wildcard Certificate, then patches
the default IngressController to `HostNetwork` with the right node selector
(`master` when `worker_count == 0`, else `worker`) and replicas.

## Conventions

- All Azure resource names are prefixed with the install-time infraID
  (extracted from `install/metadata.json`)
- Secrets (Azure SP client secret, ssh public key) flow only through
  `terraform/terraform.tfvars` (gitignored) — never logged or echoed
- After any change touching `terraform/`, run `terraform fmt && terraform
  validate` before claiming work is done
