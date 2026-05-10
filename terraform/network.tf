resource "azurerm_virtual_network" "cluster" {
  name                = "${local.infra_id}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  address_space       = [local.vnet_cidr]
  tags                = local.base_tags
}

resource "azurerm_subnet" "master" {
  name                 = "${local.infra_id}-master-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.cluster.name
  address_prefixes     = [local.master_subnet]
}

resource "azurerm_subnet" "worker" {
  name                 = "${local.infra_id}-worker-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.cluster.name
  address_prefixes     = [local.worker_subnet]
}

resource "azurerm_network_security_group" "cluster" {
  name                = "${local.infra_id}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.base_tags

  security_rule {
    name                       = "ssh-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "api-in"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "http-in"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "https-in"
    priority                   = 103
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "master" {
  subnet_id                 = azurerm_subnet.master.id
  network_security_group_id = azurerm_network_security_group.cluster.id
}

resource "azurerm_subnet_network_security_group_association" "worker" {
  subnet_id                 = azurerm_subnet.worker.id
  network_security_group_id = azurerm_network_security_group.cluster.id
}
