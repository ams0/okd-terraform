#!/usr/bin/env bash
# Idempotent cluster bringup. Use this instead of `terraform apply` directly.
#
# Why this exists: the master.ign that openshift-install produces embeds a
# Machine Config Server (MCS) bootstrap token with a 24h TTL. If you destroy
# the cluster and try to re-apply more than ~20h later with the old ignition
# files, masters will fail to pull their config and the cluster won't come up.
#
# Behavior:
# On platform: none the installer emits a DNS config with neither publicZone
# nor privateZone, so the cluster-ingress-operator cannot claim the *.apps
# records and the zone-stripping step this script used to perform is unnecessary.
#
#   - If terraform state is empty (fresh checkout or post-destroy), wipe the
#     install/ artifacts and regenerate them via `openshift-install create
#     manifests + ignition-configs`. This produces a fresh infraID + MCS token.
#   - Otherwise (existing cluster), just run `terraform apply` — DO NOT regen,
#     because that would change the infraID and force a full destroy/recreate.
#
# Pass extra flags through, e.g. `scripts/04-bringup.sh -auto-approve`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install"
TERRAFORM="$ROOT/terraform"
INSTALLER="$ROOT/.bin/openshift-install"

# Always run the fetcher: it installs the binary when missing and upgrades it
# when a newer OKD-SCOS release exists. It self-skips when already current, and
# never downgrades. Set OKD_SKIP_UPDATE_CHECK=1 to stay offline, or pin an
# exact release with OKD_VERSION.
"$ROOT/scripts/00-fetch-openshift-install.sh"
[[ -x "$INSTALLER" ]] || { echo "FATAL: $INSTALLER still missing after fetch" >&2; exit 1; }
[[ -f "$INSTALL/install-config.yaml.tpl" ]] || { echo "FATAL: $INSTALL/install-config.yaml.tpl missing" >&2; exit 1; }

# Count resources in terraform state. Prints a single integer, always.
# NOTE: must not use a pipeline whose failure escapes -o pipefail; a failing
# `terraform state list` used to make this emit "0\n0" and blow up the [[ ]]
# arithmetic comparison below.
state_count() {
  local out
  out="$(cd "$TERRAFORM" && terraform state list 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    echo 0
  else
    printf '%s\n' "$out" | grep -c . || true
  fi
}

# terraform apply refuses to run when .terraform/providers doesn't match the
# lock file (fresh checkout, pruned plugin cache, provider version bump). init
# is idempotent and cheap when already initialized, so just always run it —
# and do it before state_count(), which needs an initialized backend.
echo "==> terraform init"
( cd "$TERRAFORM" && terraform init -input=false )

needs_regen=0
if [[ ! -f "$INSTALL/master.ign" || ! -f "$INSTALL/metadata.json" ]]; then
  echo "==> install/ ignition artifacts missing → regen"
  needs_regen=1
elif [[ "$(state_count)" -lt 5 ]]; then
  echo "==> terraform state is empty → fresh bringup, regen"
  needs_regen=1
else
  mtime=$(stat -f %m "$INSTALL/master.ign" 2>/dev/null || stat -c %Y "$INSTALL/master.ign")
  age_h=$(( ( $(date +%s) - mtime ) / 3600 ))
  echo "==> existing cluster (master.ign is ${age_h}h old) — skipping regen"
fi

if [[ $needs_regen -eq 1 ]]; then
  echo "==> Cleaning install/ artifacts"
  rm -rf \
    "$INSTALL/auth" \
    "$INSTALL/manifests" \
    "$INSTALL/openshift" \
    "$INSTALL/cluster-api" \
    "$INSTALL/.openshift_install"* \
    "$INSTALL/metadata.json" \
    "$INSTALL/master.ign" \
    "$INSTALL/worker.ign" \
    "$INSTALL/bootstrap.ign" \
    "$INSTALL/bootstrap-in-place-for-live-iso.ign" \
    "$INSTALL/install-config.yaml"

  echo "==> Rendering install-config.yaml"
  "$ROOT/scripts/02-render-install-config.sh"

  master_count=$(python3 - "$ROOT/terraform/terraform.tfvars" <<'PY'
import re, sys
with open(sys.argv[1]) as f: t = f.read()
m = re.search(r'^\s*master_count\s*=\s*([0-9]+)', t, re.M)
print(m.group(1) if m else "3")
PY
)
  echo "==> Detected master_count=$master_count"

  if [[ "$master_count" == "1" ]]; then
    # Single Node OpenShift: bootstrap-in-place produces ONE ignition file that
    # the master self-applies. No `create manifests` step (the bip ignition
    # bakes them in) and no per-node ignitions.
    echo "==> openshift-install create single-node-ignition-config (SNO)"
    "$INSTALLER" create single-node-ignition-config --dir="$INSTALL"
  else
    echo "==> openshift-install create manifests"
    "$INSTALLER" create manifests --dir="$INSTALL"

    # Install the keepalived VIP layer into the master config before ignitions
    # are baked. platform: none renders no on-prem LB, so without this nothing
    # ever answers on api_vip and the cluster is unreachable.
    echo "==> Rendering keepalived MachineConfig for masters"
    "$ROOT/scripts/03-render-lb-manifests.sh" manifests

    echo "==> openshift-install create ignition-configs"
    "$INSTALLER" create ignition-configs --dir="$INSTALL"

    # bootstrap.ign is a complete config (not a pointer), so it is patched
    # after generation rather than via a MachineConfig. Bootstrap holds the API
    # VIP until a master's own apiserver outranks it.
    echo "==> Patching bootstrap.ign with keepalived"
    "$ROOT/scripts/03-render-lb-manifests.sh" bootstrap
  fi

  echo "==> Fresh infraID: $(python3 -c "import json; print(json.load(open('$INSTALL/metadata.json'))['infraID'])")"
fi

echo "==> terraform apply"
cd "$TERRAFORM"
exec terraform apply "$@"
