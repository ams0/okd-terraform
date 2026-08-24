apiVersion: v1
baseDomain: __BASE_DOMAIN__
metadata:
  name: __CLUSTER_NAME__
compute:
- name: worker
  replicas: __WORKER_COUNT__
controlPlane:
  name: master
  replicas: __MASTER_COUNT__
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: __MACHINE_NETWORK_CIDR__
  serviceNetwork:
  - 172.30.0.0/16
  networkType: OVNKubernetes
# `none` rather than `baremetal`: the baremetal platform requires
# platform.baremetal.hosts with BMC credentials, which Proxmox VMs do not have.
# The cost is that OKD renders no on-prem networking stack, so the API and
# ingress VIPs are provided by keepalived + HAProxy static pods installed from
# manifests/ (see cert-manager/manifests/lb/ and scripts/03-render-lb-manifests.sh).
platform:
  none: {}
publish: External
__BOOTSTRAP_IN_PLACE__pullSecret: '__PULL_SECRET__'
sshKey: |
  __SSH_KEY__
