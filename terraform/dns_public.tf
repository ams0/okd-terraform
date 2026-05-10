# Public Azure DNS records for the cluster.
# Both records point at TF-managed PIPs, so destroy/recreate keeps DNS in sync
# with no manual edits. *.apps relies on the IngressController being patched to
# HostNetwork strategy (see ingress.tf) so the cluster does NOT spawn its own
# CCM-managed LoadBalancer Service for ingress.

resource "azurerm_dns_a_record" "api" {
  name                = "api.okd"
  zone_name           = var.base_domain
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [azurerm_public_ip.api.ip_address]
  tags                = local.base_tags
}

resource "azurerm_dns_a_record" "apps" {
  name                = "*.apps.okd"
  zone_name           = var.base_domain
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [azurerm_public_ip.router.ip_address]
  tags                = local.base_tags
}
