#!/usr/bin/env bash
# Idempotent applier for cert-manager + ClusterIssuer + Certificate +
# IngressController patches. Invoked from terraform/cert_manager.tf.
#
# Required env:
#   KUBECONFIG, MANIFEST_DIR (rendered manifests), CLUSTER_DOMAIN
set -euo pipefail

: "${KUBECONFIG:?}"
: "${MANIFEST_DIR:?}"
: "${CLUSTER_DOMAIN:?}"

# Wait until the cluster API answers /healthz. After a fresh apply the masters
# need ~25-35 min to bootstrap, so be generous.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-2700}"  # 45 min
echo "==> Waiting up to ${WAIT_TIMEOUT}s for cluster API to be ready"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
until kubectl --request-timeout=5s get --raw=/healthz >/dev/null 2>&1; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "Cluster API did not become ready within ${WAIT_TIMEOUT}s" >&2
    exit 1
  fi
  echo "  $(date -u +%H:%M:%S) api not ready yet, retrying in 30s..."
  sleep 30
done
echo "==> Cluster API ready"

# Wait only for kube-apiserver to be Available (others — authentication, console,
# ingress — can't converge until we switch the IngressController to HostNetwork
# below, so waiting on all clusteroperators here would deadlock on initial bringup).
#
# Two traps here, both hit on a fresh bringup:
#   1. The /healthz gate above is satisfied by the BOOTSTRAP node's temporary
#      control plane, which answers long before the CVO has created any
#      ClusterOperator resources. `kubectl wait` does not wait for a resource to
#      exist — it exits immediately with NotFound — so it must not be the first
#      thing that touches the CR. Poll for existence first.
#   2. The API connection drops during the bootstrap -> permanent control plane
#      handoff. Any single kubectl call can fail transiently, so both loops
#      tolerate errors instead of treating them as fatal.
CO_TIMEOUT="${CO_TIMEOUT:-2700}"  # 45 min
co_deadline=$(( $(date +%s) + CO_TIMEOUT ))

echo "==> Waiting up to ${CO_TIMEOUT}s for kube-apiserver clusteroperator to exist"
until kubectl --request-timeout=10s get clusteroperator kube-apiserver >/dev/null 2>&1; do
  if (( $(date +%s) >= co_deadline )); then
    echo "kube-apiserver clusteroperator was never created within ${CO_TIMEOUT}s" >&2
    echo "The control plane is likely still bootstrapping; check the bootstrap node console." >&2
    exit 1
  fi
  echo "  $(date -u +%H:%M:%S) clusteroperators not created yet, retrying in 30s..."
  sleep 30
done

echo "==> Waiting for kube-apiserver clusteroperator to be Available"
until [[ "$(kubectl --request-timeout=10s get clusteroperator kube-apiserver \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == "True" ]]; do
  if (( $(date +%s) >= co_deadline )); then
    echo "kube-apiserver clusteroperator did not become Available within ${CO_TIMEOUT}s" >&2
    kubectl get clusteroperator kube-apiserver >&2 || true
    exit 1
  fi
  echo "  $(date -u +%H:%M:%S) kube-apiserver not Available yet, retrying in 30s..."
  sleep 30
done
echo "==> kube-apiserver clusteroperator Available"

# Defense-in-depth: clear publicZone/privateZone from the cluster DNS config so
# the cluster-ingress-operator does NOT take ownership of *.apps.<base_domain>
# DNS records. The bringup script already strips this from the install manifest
# pre-ignition, but keep this here so an existing cluster (or one provisioned
# without 04-bringup.sh) still gets the right behavior.
echo "==> Ensuring cluster DNS config has no managed zones"
needs_dns_patch=0
kubectl get dns.config.openshift.io cluster -o json | python3 -c "import json,sys; s=json.load(sys.stdin)['spec']; sys.exit(0 if (s.get('publicZone') or s.get('privateZone')) else 1)" \
  && needs_dns_patch=1
if [[ $needs_dns_patch -eq 1 ]]; then
  echo "  removing publicZone/privateZone"
  kubectl patch dns.config.openshift.io cluster --type=json -p='[
    {"op":"remove","path":"/spec/publicZone"},
    {"op":"remove","path":"/spec/privateZone"}
  ]' || true
fi

echo "==> Applying cert-manager static manifests"
kubectl apply -f "${MANIFEST_DIR}/01-cert-manager.yaml"

echo "==> Waiting for cert-manager CRDs"
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager        --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s

echo "==> Patching cert-manager controller to use public recursive DNS"
# The cluster's private DNS zone for okd.${CLUSTER_DOMAIN} shadows the public
# zone for the controller's authoritative-NS lookup. Force public resolvers.
needs_patch=1
if kubectl -n cert-manager get deploy cert-manager -o json | \
    grep -q -- "--dns01-recursive-nameservers-only"; then
  needs_patch=0
fi
if [[ $needs_patch -eq 1 ]]; then
  kubectl -n cert-manager patch deploy cert-manager --type=json -p '[
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers-only"},
    {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53"}
  ]'
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
fi

echo "==> Ensuring default IngressController uses HostNetwork strategy"
# In a UPI cluster the cluster-ingress-operator creates a default IngressController
# with strategy=LoadBalancerService, which makes the Azure cloud-controller-manager
# allocate a separate external LB IP for router-default. That conflicts with the
# pre-created TF router LB our public DNS *.apps record points at. Switch to
# HostNetwork so router pods bind master :80/:443 directly (matches the TF LB
# rules and master NSG inbound 80/443).
echo "  waiting up to 10m for cluster-ingress-operator to create default IngressController"
deadline=$(( $(date +%s) + 600 ))
until kubectl -n openshift-ingress-operator get ingresscontroller default >/dev/null 2>&1; do
  if (( $(date +%s) >= deadline )); then
    echo "Timeout waiting for default IngressController to exist" >&2
    exit 1
  fi
  sleep 10
done

current_strategy=$(kubectl -n openshift-ingress-operator get ingresscontroller default \
  -o jsonpath='{.spec.endpointPublishingStrategy.type}' 2>/dev/null || true)
if [[ "$current_strategy" != "HostNetwork" ]]; then
  echo "  current strategy: '${current_strategy:-<absent>}', deleting and re-creating"
  kubectl -n openshift-ingress-operator delete ingresscontroller default --ignore-not-found
  echo "  waiting for router-default Service to be removed (so CCM cleans up its LB)"
  for _ in $(seq 1 60); do
    kubectl -n openshift-ingress get svc router-default >/dev/null 2>&1 || break
    sleep 5
  done
fi
kubectl apply -f "${MANIFEST_DIR}/05-ingress-controller.yaml"

expected_replicas=$(kubectl -n openshift-ingress-operator get ingresscontroller default \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
echo "==> Waiting for ${expected_replicas} router pods to be Ready"
deadline=$(( $(date +%s) + 600 ))
while :; do
  ready=$(kubectl -n openshift-ingress get pods \
    -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
    --no-headers 2>/dev/null | awk '$2 == "1/1" && $3 == "Running"' | wc -l | tr -d ' ')
  if [[ "${ready:-0}" -ge "${expected_replicas}" ]]; then
    echo "  ${ready}/${expected_replicas} router pods Ready"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "Timeout waiting for router pods (have ${ready:-0}/${expected_replicas} Ready)" >&2
    kubectl -n openshift-ingress get pods >&2
    exit 1
  fi
  echo "  $(date -u +%H:%M:%S) router pods ${ready:-0}/${expected_replicas} Ready"
  sleep 15
done

echo "==> Applying Azure DNS Secret + ClusterIssuer + Certificate"
kubectl apply -f "${MANIFEST_DIR}/02-azure-dns-secret.yaml"
kubectl apply -f "${MANIFEST_DIR}/03-cluster-issuer.yaml"
kubectl apply -f "${MANIFEST_DIR}/04-apps-wildcard-cert.yaml"

echo "==> Waiting for Certificate to become Ready (DNS-01 challenge can take 3-10 min)"
kubectl -n openshift-ingress wait --for=condition=Ready certificate/apps-wildcard --timeout=900s

echo "==> Patching default IngressController to serve apps-tls-cert"
kubectl -n openshift-ingress-operator patch ingresscontroller default --type=merge -p '{
  "spec":{"defaultCertificate":{"name":"apps-tls-cert"}}
}'

echo "==> Done."
