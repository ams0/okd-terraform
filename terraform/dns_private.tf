resource "azurerm_private_dns_zone" "cluster" {
  name                = "${local.cluster_name}.${var.base_domain}"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.base_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cluster" {
  name                  = "${local.infra_id}-pdz-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = azurerm_virtual_network.cluster.id
  registration_enabled  = false
  tags                  = local.base_tags
}

resource "azurerm_private_dns_a_record" "api_internal" {
  name                = "api-int"
  zone_name           = azurerm_private_dns_zone.cluster.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records             = [azurerm_lb.internal.frontend_ip_configuration[0].private_ip_address]
}

resource "azurerm_private_dns_a_record" "api" {
  name                = "api"
  zone_name           = azurerm_private_dns_zone.cluster.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records             = [azurerm_lb.internal.frontend_ip_configuration[0].private_ip_address]
}

# In-cluster wildcard for *.apps.<cluster>. The private DNS zone for
# okd.<base_domain> is authoritative inside the VNet, so it shadows the public
# zone for these lookups. Without this record, in-cluster components like the
# authentication, console, and ingress operators that health-check their own
# public route get NXDOMAIN, and console login fails with "Authentication error".
#
# Router pods run with HostNetwork on whichever tier carries ingress: workers
# when present, otherwise masters. Multi-record round-robin gives a small
# amount of resilience.
resource "azurerm_private_dns_a_record" "apps_wildcard" {
  name                = "*.apps"
  zone_name           = azurerm_private_dns_zone.cluster.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 60
  records = local.router_targets_workers ? [
    for nic in azurerm_network_interface.worker : nic.private_ip_address
    ] : [
    for nic in azurerm_network_interface.master : nic.private_ip_address
  ]
  tags = local.base_tags
}
