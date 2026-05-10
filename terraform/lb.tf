############################
# External (public) API LB
############################

resource "azurerm_public_ip" "api" {
  name                = "${local.infra_id}-api-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.base_tags
}

resource "azurerm_lb" "external" {
  name                = local.infra_id
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Standard"
  tags                = local.base_tags

  frontend_ip_configuration {
    name                 = "public-lb-ip-v4"
    public_ip_address_id = azurerm_public_ip.api.id
  }

  # The Azure cloud-controller-manager (CCM) adds hash-named frontend IPs +
  # rules to this LB for each LoadBalancer-type Service (e.g. router-default).
  # Ignore so TF doesn't fight CCM and break apply with stale rule references.
  lifecycle {
    ignore_changes = [frontend_ip_configuration]
  }
}

resource "azurerm_lb_backend_address_pool" "external" {
  loadbalancer_id = azurerm_lb.external.id
  name            = "${local.infra_id}-public-backend-pool"
}

resource "azurerm_lb_probe" "external_api" {
  loadbalancer_id     = azurerm_lb.external.id
  name                = "api-probe"
  protocol            = "Https"
  request_path        = "/readyz"
  port                = 6443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "external_api" {
  loadbalancer_id                = azurerm_lb.external.id
  name                           = "api-v4"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = azurerm_lb.external.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.external.id]
  probe_id                       = azurerm_lb_probe.external_api.id
  disable_outbound_snat          = true
  load_distribution              = "Default"
  idle_timeout_in_minutes        = 30
}

resource "azurerm_lb_outbound_rule" "external" {
  name                     = "outbound-rule-v4"
  loadbalancer_id          = azurerm_lb.external.id
  protocol                 = "All"
  enable_tcp_reset         = false
  allocated_outbound_ports = 1024
  backend_address_pool_id  = azurerm_lb_backend_address_pool.external.id

  frontend_ip_configuration {
    name = azurerm_lb.external.frontend_ip_configuration[0].name
  }
}

############################
# Internal LB (api-int + MCS)
############################

resource "azurerm_lb" "internal" {
  name                = "${local.infra_id}-internal"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Standard"
  tags                = local.base_tags

  frontend_ip_configuration {
    name                          = "internal-lb-ip-v4"
    subnet_id                     = azurerm_subnet.master.id
    private_ip_address_allocation = "Dynamic"
    private_ip_address_version    = "IPv4"
  }
}

resource "azurerm_lb_backend_address_pool" "internal" {
  loadbalancer_id = azurerm_lb.internal.id
  name            = "${local.infra_id}-internal-backend-pool"
}

resource "azurerm_lb_probe" "internal_api" {
  loadbalancer_id     = azurerm_lb.internal.id
  name                = "api-internal-probe"
  protocol            = "Https"
  request_path        = "/readyz"
  port                = 6443
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_probe" "internal_mcs" {
  loadbalancer_id     = azurerm_lb.internal.id
  name                = "machine-config-probe"
  protocol            = "Https"
  request_path        = "/healthz"
  port                = 22623
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "internal_api" {
  loadbalancer_id                = azurerm_lb.internal.id
  name                           = "api-internal-v4"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = azurerm_lb.internal.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
  probe_id                       = azurerm_lb_probe.internal_api.id
  load_distribution              = "Default"
  idle_timeout_in_minutes        = 30
}

resource "azurerm_lb_rule" "internal_mcs" {
  loadbalancer_id                = azurerm_lb.internal.id
  name                           = "machine-config-server-v4"
  protocol                       = "Tcp"
  frontend_port                  = 22623
  backend_port                   = 22623
  frontend_ip_configuration_name = azurerm_lb.internal.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.internal.id]
  probe_id                       = azurerm_lb_probe.internal_mcs.id
  load_distribution              = "Default"
  idle_timeout_in_minutes        = 30
}

############################
# Router (ingress) LB
############################

resource "azurerm_public_ip" "router" {
  name                = "${local.infra_id}-router-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.base_tags
}

resource "azurerm_lb" "router" {
  name                = "${local.infra_id}-router"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Standard"
  tags                = local.base_tags

  frontend_ip_configuration {
    name                 = "router-frontend"
    public_ip_address_id = azurerm_public_ip.router.id
  }
}

resource "azurerm_lb_backend_address_pool" "router" {
  loadbalancer_id = azurerm_lb.router.id
  name            = "${local.infra_id}-router-backend-pool"
}

resource "azurerm_lb_probe" "router" {
  loadbalancer_id     = azurerm_lb.router.id
  name                = "router-probe"
  protocol            = "Tcp"
  port                = 1936
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "router_http" {
  loadbalancer_id                = azurerm_lb.router.id
  name                           = "http"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = azurerm_lb.router.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.router.id]
  probe_id                       = azurerm_lb_probe.router.id
}

resource "azurerm_lb_rule" "router_https" {
  loadbalancer_id                = azurerm_lb.router.id
  name                           = "https"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = azurerm_lb.router.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.router.id]
  probe_id                       = azurerm_lb_probe.router.id
}
