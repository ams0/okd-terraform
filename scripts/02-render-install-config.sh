#!/usr/bin/env bash
# Render install/install-config.yaml from .tpl by substituting values from
# terraform.tfvars (cluster name, base domain, replicas, machine network) plus
# the pull secret on disk. Reads sensitive values from disk; nothing is echoed.
#
# For Single Node OpenShift (master_count == 1) a `bootstrapInPlace` block is
# emitted; otherwise it's omitted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$ROOT/install/install-config.yaml.tpl"
OUT="$ROOT/install/install-config.yaml"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-${HOME}/Downloads/pull-secret.txt}"
TFVARS="$ROOT/terraform/terraform.tfvars"

# Fail with something readable instead of a Python traceback from inside the
# heredoc — a missing pull secret is the single most common first-run blocker.
[[ -f "$PULL_SECRET_FILE" ]] || {
  echo "FATAL: pull secret not found at $PULL_SECRET_FILE" >&2
  echo "       Download it from https://console.redhat.com/openshift/install/pull-secret" >&2
  echo "       and save it there, or point PULL_SECRET_FILE at another path." >&2
  exit 1
}
[[ -f "$TFVARS" ]] || { echo "FATAL: $TFVARS missing (copy terraform.tfvars.example)" >&2; exit 1; }

python3 - "$TPL" "$OUT" "$PULL_SECRET_FILE" "$TFVARS" <<'PY'
import re, sys

tpl_path, out_path, ps_path, tfvars_path = sys.argv[1:]

with open(ps_path) as f:
    pull_secret = f.read().strip()

with open(tfvars_path) as f:
    tfvars = f.read()

def get_var(name, default=None):
    # Match `name = "value"` or `name = 123` (unquoted numbers)
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*"([^"]*)"', tfvars, re.M)
    if m:
        return m.group(1)
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*([0-9]+)\s*$', tfvars, re.M)
    if m:
        return m.group(1)
    if default is None:
        sys.exit(f"{name} not found in {tfvars_path}")
    return default

ssh_key       = get_var("ssh_public_key")
master_count  = get_var("master_count", "3")
worker_count  = get_var("worker_count", "0")
base_domain   = get_var("base_domain", "techmasters.cloud")

# The machine network has to match the subnet the Proxmox bridge is on, or the
# installer records the wrong node CIDR and kubelet picks the wrong address.
machine_network_cidr = get_var("machine_network_cidr")

# Fixed, derived from install-config metadata.name (kept in template as cluster name)
cluster_name   = "okd"

if master_count not in ("1", "3"):
    sys.exit(f"master_count must be 1 or 3, got {master_count}")

# bootstrap-in-place applies only to SNO (master_count == 1). On Proxmox the
# root disk is attached as virtio0, which the guest sees as /dev/vda — not
# /dev/sda as on Azure. Getting this wrong makes the single-node install target
# a device that does not exist.
if master_count == "1":
    bip_block = (
        "bootstrapInPlace:\n"
        "  installationDisk: /dev/vda\n"
    )
else:
    bip_block = ""

with open(tpl_path) as f:
    out = f.read()

out = (
    out.replace("__BASE_DOMAIN__", base_domain)
       .replace("__CLUSTER_NAME__", cluster_name)
       .replace("__MACHINE_NETWORK_CIDR__", machine_network_cidr)
       .replace("__MASTER_COUNT__", master_count)
       .replace("__WORKER_COUNT__", worker_count)
       .replace("__BOOTSTRAP_IN_PLACE__", bip_block)
       .replace("__PULL_SECRET__", pull_secret)
       .replace("__SSH_KEY__", ssh_key)
)

with open(out_path, "w") as f:
    f.write(out)

print(f"wrote {out_path} ({len(out)} bytes) — platform=none, "
      f"masters={master_count}, workers={worker_count}, "
      f"machineNetwork={machine_network_cidr}, "
      f"sno={'yes' if master_count=='1' else 'no'}")
PY
