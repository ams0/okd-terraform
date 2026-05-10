resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.cluster_id}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "master_subnet" {
  name                 = "${var.cluster_id}-master-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "worker_subnet" {
  name                 = "${var.cluster_id}-worker-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Load Balancer for API
resource "azurerm_public_ip" "api_lb_pip" {
  name                = "${var.cluster_id}-api-lb-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "api_lb" {
  name                = "${var.cluster_id}-api-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "api-ip-config"
    public_ip_address_id = azurerm_public_ip.api_lb_pip.id
  }
}

# Load Balancer for Ingress (Apps)
resource "azurerm_public_ip" "ingress_lb_pip" {
  name                = "${var.cluster_id}-ingress-lb-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "ingress_lb" {
  name                = "${var.cluster_id}-ingress-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "ingress-ip-config"
    public_ip_address_id = azurerm_public_ip.ingress_lb_pip.id
  }
}

# Master VMs (Simplified for scaffolding)
resource "azurerm_network_interface" "master_nic" {
  count               = var.master_count
  name                = "${var.cluster_id}-master-nic-${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.master_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "master_vm" {
  count               = var.master_count
  name                = "${var.cluster_id}-master-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D4s_v3"
  admin_username      = "core"
  network_interface_ids = [
    azurerm_network_interface.master_nic[count.index].id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "RedHat" # Placeholder, OKD usually uses FCOS
    offer     = "RHEL"
    sku       = "8-LVM"
    version   = "latest"
  }

  tags = var.tags
}

# Worker VMs
resource "azurerm_network_interface" "worker_nic" {
  count               = var.worker_count
  name                = "${var.cluster_id}-worker-nic-${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.worker_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "worker_vm" {
  count               = var.worker_count
  name                = "${var.cluster_id}-worker-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D4s_v3"
  admin_username      = "core"
  network_interface_ids = [
    azurerm_network_interface.worker_nic[count.index].id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "RedHat" # Placeholder
    offer     = "RHEL"
    sku       = "8-LVM"
    version   = "latest"
  }

  tags = var.tags
}
