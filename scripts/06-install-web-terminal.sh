#!/usr/bin/env bash
# Install the Red Hat operators catalog and the web-terminal-operator on top
# of an OKD/OKD-SCOS cluster. OKD ships only `community-operators` by default;
# web-terminal-operator lives in `redhat-operators`, which is what this script
# wires up. Idempotent.
#
# Pull access to registry.redhat.io is required. If your install pull-secret
# already has redhat.io credentials (typical when you reused an OCP pull-secret
# for OKD), this works as-is. Otherwise use:
#   oc registry login --registry registry.redhat.io --auth-basic <user>:<token>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/install/auth/kubeconfig}"

# Match the catalog index tag to the cluster's minor version.
OCP_MINOR="$(kubectl get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F. '{print $1"."$2}')"
INDEX_TAG="v${OCP_MINOR}"
INDEX_IMAGE="registry.redhat.io/redhat/redhat-operator-index:${INDEX_TAG}"

echo "==> Cluster version: $(kubectl get clusterversion version -o jsonpath='{.status.desired.version}')"
echo "==> Will use Red Hat operator index: $INDEX_IMAGE"

echo "==> Applying redhat-operators CatalogSource"
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $INDEX_IMAGE
  displayName: Red Hat Operators
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

echo "==> Waiting for CatalogSource to be READY (image pull + grpc serving can take 2-5 min)"
deadline=$(( $(date +%s) + 600 ))
while :; do
  state=$(kubectl -n openshift-marketplace get catalogsource redhat-operators \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [[ "$state" == "READY" ]]; then
    echo "  CatalogSource READY"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "Timeout. Check pod logs:" >&2
    kubectl -n openshift-marketplace get pods -l olm.catalogSource=redhat-operators >&2
    exit 1
  fi
  echo "  $(date -u +%H:%M:%S) state=${state:-pending}"
  sleep 10
done

echo "==> Applying web-terminal Subscription"
kubectl apply -f "$ROOT/web-terminal.yaml"

echo "==> Waiting for web-terminal CSV to succeed"
deadline=$(( $(date +%s) + 600 ))
while :; do
  csv=$(kubectl -n openshift-operators get csv -o name 2>/dev/null | grep -i web-terminal | head -1 | sed 's|.*/||')
  if [[ -n "$csv" ]]; then
    phase=$(kubectl -n openshift-operators get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Succeeded" ]]; then
      echo "  CSV $csv: Succeeded"
      break
    fi
    echo "  $(date -u +%H:%M:%S) CSV $csv phase=${phase:-Pending}"
  else
    echo "  $(date -u +%H:%M:%S) waiting for CSV to appear"
  fi
  if (( $(date +%s) >= deadline )); then
    echo "Timeout. Check Subscription + InstallPlan in openshift-operators." >&2
    kubectl -n openshift-operators get sub,ip,csv | tail >&2
    exit 1
  fi
  sleep 15
done

echo "==> Done. Reload the web console — the terminal icon (>_) should appear in the masthead."
