#!/usr/bin/env bash
# Publishes VIP health as flag files for keepalived to consult.
#
# Why a flag file rather than letting keepalived run the probe directly:
# keepalived executes its vrrp_script inside its own container, so any probe it
# runs depends on that image shipping curl, the right CA bundle, and so on.
# Doing the probing here on the host — which definitely has curl — and reducing
# keepalived's check to `test -f` keeps the container contract to nothing.
#
# Runs as a plain loop rather than a systemd timer: one unit instead of two, and
# a sub-10s interval is awkward to express as a timer anyway.
set -uo pipefail

STATE_DIR=/etc/keepalived/state
INTERVAL="${INTERVAL:-5}"

# 6443 = kube-apiserver. On the bootstrap node this is the temporary control
# plane, on a master it is the real one; either way /readyz answering means this
# host can serve the API VIP.
API_URL="https://localhost:6443/readyz"

# 1936 is the OpenShift router's stats/health port. Checking it — rather than
# :443 — distinguishes "a router pod is running here" from "something is
# listening", which matters because the ingress VIP must only land on a node
# actually running a router.
INGRESS_URL="http://localhost:1936/healthz"

mkdir -p "$STATE_DIR"

flag() {
  local name="$1" ok="$2"
  if [[ "$ok" == "yes" ]]; then
    touch "$STATE_DIR/$name"
  else
    rm -f "$STATE_DIR/$name"
  fi
}

while :; do
  if curl -sk --max-time 4 -o /dev/null "$API_URL"; then
    flag api-healthy yes
  else
    flag api-healthy no
  fi

  if [[ "${CHECK_INGRESS:-1}" == "1" ]]; then
    if curl -s --max-time 4 -o /dev/null "$INGRESS_URL"; then
      flag ingress-healthy yes
    else
      flag ingress-healthy no
    fi
  fi

  sleep "$INTERVAL"
done
