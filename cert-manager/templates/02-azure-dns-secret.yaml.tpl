apiVersion: v1
kind: Secret
metadata:
  name: azure-dns-credential
  namespace: cert-manager
type: Opaque
stringData:
  client-secret: ${client_secret}
