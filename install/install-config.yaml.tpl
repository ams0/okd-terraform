apiVersion: v1
baseDomain: __BASE_DOMAIN__
metadata:
  name: __CLUSTER_NAME__
compute:
- name: worker
  replicas: __WORKER_COUNT__
  platform:
    azure:
      type: __WORKER_VM_SIZE__
      osDisk:
        diskSizeGB: 128
controlPlane:
  name: master
  replicas: __MASTER_COUNT__
  platform:
    azure:
      type: __MASTER_VM_SIZE__
      osDisk:
        diskSizeGB: 128
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
  networkType: OVNKubernetes
platform:
  azure:
    region: __REGION__
    baseDomainResourceGroupName: __DNS_RG__
    cloudName: AzurePublicCloud
    outboundType: Loadbalancer
publish: External
__BOOTSTRAP_IN_PLACE__pullSecret: '__PULL_SECRET__'
sshKey: |
  __SSH_KEY__
