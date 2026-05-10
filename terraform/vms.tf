############################
# Bootstrap VM (3-CP only)
############################
# In SNO mode (master_count == 1) the master self-bootstraps via the
# bootstrap-in-place ignition, so no bootstrap VM is needed.

resource "azurerm_network_interface" "bootstrap" {
  count               = local.single_node ? 0 : 1
  name                = "${local.infra_id}-bootstrap-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.base_tags

  ip_configuration {
    name                          = "bootstrap-config"
    subnet_id                     = azurerm_subnet.master.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "bootstrap_external" {
  count                   = local.single_node ? 0 : 1
  network_interface_id    = azurerm_network_interface.bootstrap[0].id
  ip_configuration_name   = "bootstrap-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.external.id
}

resource "azurerm_network_interface_backend_address_pool_association" "bootstrap_internal" {
  count                   = local.single_node ? 0 : 1
  network_interface_id    = azurerm_network_interface.bootstrap[0].id
  ip_configuration_name   = "bootstrap-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.internal.id
}

resource "azurerm_linux_virtual_machine" "bootstrap" {
  count                           = local.single_node ? 0 : 1
  name                            = "${local.infra_id}-bootstrap"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  size                            = var.bootstrap_vm_size
  admin_username                  = "core"
  network_interface_ids           = [azurerm_network_interface.bootstrap[0].id]
  computer_name                   = "${local.infra_id}-bootstrap"
  disable_password_authentication = true

  custom_data = base64encode(local.bootstrap_stub_ignition)

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 100
  }

  source_image_id = azurerm_image.scos.id
  tags            = local.base_tags

  # custom_data embeds a per-apply SAS (start=timestamp()), which would
  # otherwise force replacement on every apply. The bootstrap VM only reads
  # ignition once at first boot, so post-boot drift is harmless.
  lifecycle {
    ignore_changes = [custom_data]
  }

  depends_on = [
    azurerm_lb_rule.external_api,
    azurerm_lb_rule.internal_api,
    azurerm_lb_rule.internal_mcs,
  ]
}

############################
# Master VMs
############################
# 3-CP HA: master.ign (small, fits in custom_data directly).
# SNO    : master fetches single-node bootstrap-in-place ignition via SAS-stub
#          (same pattern as bootstrap VM in 3-CP mode).

resource "azurerm_network_interface" "master" {
  count               = local.master_count
  name                = "${local.infra_id}-master${count.index}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.base_tags

  ip_configuration {
    name                          = "master${count.index}-config"
    subnet_id                     = azurerm_subnet.master.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "master_external" {
  count                   = local.master_count
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "master${count.index}-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.external.id
}

resource "azurerm_network_interface_backend_address_pool_association" "master_internal" {
  count                   = local.master_count
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "master${count.index}-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.internal.id
}

# Masters carry router traffic only when there are no workers (compact mode).
resource "azurerm_network_interface_backend_address_pool_association" "master_router" {
  count                   = local.router_targets_workers ? 0 : local.master_count
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "master${count.index}-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.router.id
}

resource "azurerm_linux_virtual_machine" "master" {
  count                           = local.master_count
  name                            = "${local.infra_id}-master-${count.index}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  size                            = var.master_vm_size
  admin_username                  = "core"
  network_interface_ids           = [azurerm_network_interface.master[count.index].id]
  computer_name                   = "${local.infra_id}-master-${count.index}"
  zone                            = tostring(count.index + 1)
  disable_password_authentication = true

  custom_data = base64encode(
    local.single_node ? local.bootstrap_stub_ignition : local.master_ign
  )

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_id = azurerm_image.scos.id
  tags            = local.base_tags

  # In SNO mode custom_data carries a per-apply SAS, same idempotency story
  # as the bootstrap VM. Ignored after first boot.
  lifecycle {
    ignore_changes = [custom_data]
  }

  depends_on = [
    azurerm_lb_rule.external_api,
    azurerm_lb_rule.internal_api,
    azurerm_lb_rule.internal_mcs,
  ]
}

############################
# Worker VMs (optional)
############################

resource "azurerm_network_interface" "worker" {
  count               = local.worker_count
  name                = "${local.infra_id}-worker${count.index}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.base_tags

  ip_configuration {
    name                          = "worker${count.index}-config"
    subnet_id                     = azurerm_subnet.worker.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Workers carry router traffic when present.
resource "azurerm_network_interface_backend_address_pool_association" "worker_router" {
  count                   = local.router_targets_workers ? local.worker_count : 0
  network_interface_id    = azurerm_network_interface.worker[count.index].id
  ip_configuration_name   = "worker${count.index}-config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.router.id
}

resource "azurerm_linux_virtual_machine" "worker" {
  count                           = local.worker_count
  name                            = "${local.infra_id}-worker-${count.index}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  size                            = var.worker_vm_size
  admin_username                  = "core"
  network_interface_ids           = [azurerm_network_interface.worker[count.index].id]
  computer_name                   = "${local.infra_id}-worker-${count.index}"
  zone                            = tostring((count.index % 3) + 1)
  disable_password_authentication = true

  custom_data = base64encode(local.worker_ign)

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_id = azurerm_image.scos.id
  tags            = local.base_tags

  depends_on = [
    azurerm_lb_rule.internal_api,
    azurerm_lb_rule.internal_mcs,
  ]
}
