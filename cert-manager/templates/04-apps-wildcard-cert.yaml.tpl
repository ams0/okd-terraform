apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apps-wildcard
  namespace: openshift-ingress
spec:
  secretName: apps-tls-cert
  duration: 2160h    # 90 days
  renewBefore: 720h  # 30 days
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: "*.apps.${cluster_domain}"
  dnsNames:
    - "*.apps.${cluster_domain}"
