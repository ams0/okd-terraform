# Public Azure DNS records for the cluster.
#
# Proxmox has no DNS service of its own, so the public zone stays on Azure DNS.
# That also keeps the cert-manager DNS-01 flow (ClusterIssuer + wildcard
# Certificate) working exactly as it did on the Azure branch.
#
# Both records point at keepalived VIPs rather than cloud load balancer IPs.
# The VIPs are configuration, not discovered attributes, so DNS no longer has
# to wait on infrastructure to report an address.
#
# Unlike the Azure branch there is no private/split-horizon zone: under
# `platform: none` the installer emits a DNS config with no publicZone or
# privateZone, so the cluster-ingress-operator never claims these records and
# in-cluster resolution follows the node's own resolv.conf.

resource "azurerm_dns_a_record" "api" {
  name                = "api.${local.cluster_name}"
  zone_name           = var.base_domain
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [var.api_vip]
}

resource "azurerm_dns_a_record" "apps" {
  name                = "*.apps.${local.cluster_name}"
  zone_name           = var.base_domain
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [var.ingress_vip]
}

# api-int is what the cluster's own components use to reach the API. On Azure
# this lived in the private zone; with no private zone it has to resolve
# publicly, and it points at the same VIP as api.
resource "azurerm_dns_a_record" "api_int" {
  name                = "api-int.${local.cluster_name}"
  zone_name           = var.base_domain
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [var.api_vip]
}
