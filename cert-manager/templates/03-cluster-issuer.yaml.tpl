apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          azureDNS:
            clientID: ${client_id}
            clientSecretSecretRef:
              name: azure-dns-credential
              key: client-secret
            subscriptionID: ${subscription_id}
            tenantID: ${tenant_id}
            resourceGroupName: ${dns_rg}
            hostedZoneName: ${zone_name}
            environment: AzurePublicCloud
        selector:
          dnsZones:
            - ${zone_name}
