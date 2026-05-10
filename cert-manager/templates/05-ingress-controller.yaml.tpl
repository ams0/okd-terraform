# Default IngressController for an OKD cluster on Azure UPI.
#
# HostNetwork strategy: router pods bind their host's :80/:443 directly. This
# matches the pre-created TF router LB (rule :80 -> :80, :443 -> :443) and the
# master/worker NSG inbound 80/443 rules. It also stops the Azure
# cloud-controller-manager from creating a separate LoadBalancer Service IP
# (which would conflict with our DNS pointing at the TF router LB IP).
#
# Node placement is computed by Terraform: when worker_count > 0, routers run
# on workers; otherwise (compact / SNO) they run on masters with a master
# toleration.
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  domain: apps.${cluster_domain}
  replicas: ${replicas}
  endpointPublishingStrategy:
    type: HostNetwork
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/${target_role}: ""
%{ if target_role == "master" ~}
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
%{ endif ~}
