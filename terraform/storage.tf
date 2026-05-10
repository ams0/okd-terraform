resource "random_string" "sa_suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_storage_account" "cluster" {
  name                            = substr("${replace(local.infra_id, "-", "")}${random_string.sa_suffix.result}", 0, 24)
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  tags                            = local.base_tags
}

resource "azurerm_storage_container" "vhd" {
  name                  = "vhd"
  storage_account_name  = azurerm_storage_account.cluster.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "ignition" {
  name                  = "ignition"
  storage_account_name  = azurerm_storage_account.cluster.name
  container_access_type = "private"
}

# SCOS VHD lives in a pre-existing storage account (contostore/images/scos.vhd).
# Image creation copies the blob into a managed-disk-backed image (~5-15 min).
resource "azurerm_image" "scos" {
  name                = "${local.infra_id}-image"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  hyper_v_generation  = "V2"

  os_disk {
    os_type  = "Linux"
    os_state = "Generalized"
    blob_uri = var.scos_vhd_blob_uri
    caching  = "ReadWrite"
  }

  tags = local.base_tags

  # Existing image keeps its original blob_uri — switching the VHD source SA
  # (e.g. moving from cluster-SA to a persistent shared SA) must not trigger
  # an in-place rebuild of a running cluster. A destroy/recreate uses the
  # current var.scos_vhd_blob_uri at create time.
  lifecycle {
    ignore_changes = [os_disk[0].blob_uri]
  }
}

# Bootstrap ignition (~300 KB block blob) — only created in 3-CP HA mode.
# In SNO mode (master_count == 1) the master bootstraps in-place, see
# `master_ignition` blob below.
resource "azurerm_storage_blob" "bootstrap_ignition" {
  count                  = local.single_node ? 0 : 1
  name                   = "bootstrap.ign"
  storage_account_name   = azurerm_storage_account.cluster.name
  storage_container_name = azurerm_storage_container.ignition.name
  type                   = "Block"
  source                 = "${path.module}/../install/bootstrap.ign"
}

# Single-node bootstrap-in-place ignition (~1 MB block blob) — only created
# in SNO mode. The master VM consumes this via a SAS-stub in custom_data.
resource "azurerm_storage_blob" "master_ignition" {
  count                  = local.single_node ? 1 : 0
  name                   = "bootstrap-in-place-for-live-iso.ign"
  storage_account_name   = azurerm_storage_account.cluster.name
  storage_container_name = azurerm_storage_container.ignition.name
  type                   = "Block"
  source                 = "${path.module}/../install/bootstrap-in-place-for-live-iso.ign"
}

data "azurerm_storage_account_sas" "bootstrap" {
  connection_string = azurerm_storage_account.cluster.primary_connection_string
  https_only        = true
  signed_version    = "2022-11-02"

  resource_types {
    service   = false
    container = false
    object    = true
  }
  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start  = timestamp()
  expiry = timeadd(timestamp(), "24h")

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

locals {
  ignition_blob_url = local.single_node ? azurerm_storage_blob.master_ignition[0].url : azurerm_storage_blob.bootstrap_ignition[0].url
  bootstrap_url     = "${local.ignition_blob_url}?${data.azurerm_storage_account_sas.bootstrap.sas}"

  bootstrap_stub_ignition = jsonencode({
    ignition = {
      version = "3.2.0"
      config = {
        replace = {
          source = local.bootstrap_url
        }
      }
    }
  })
}
