# SCOS node image.
#
# On Azure this was an azurerm_image built from a VHD page blob the operator
# had to stage by hand. Proxmox pulls the qcow2 itself through the PVE
# download-url API, so the image lands straight on the node and never transits
# the machine running Terraform.
#
# Prerequisites on the target datastore:
#   - `import` must be added to its allowed content types (off by default).
#     The `iso` type would also work, but PVE rejects a `.qcow2` extension for
#     iso content on PVE < 8.4, and `import` is the documented path for
#     uncompressed disk images.
#   - The API token needs Datastore.AllocateTemplate plus Sys.Audit and
#     Sys.Modify.
resource "proxmox_download_file" "scos" {
  node_name    = var.proxmox_node
  datastore_id = var.proxmox_iso_datastore
  content_type = "import"

  url                = var.scos_image_url
  checksum           = var.scos_image_checksum
  checksum_algorithm = var.scos_image_checksum == null ? null : var.scos_image_checksum_algorithm

  # Stable name so re-applies reuse the existing download instead of re-pulling
  # several GB. Scoped by infra_id so two clusters never collide.
  file_name = "scos-${local.infra_id}.qcow2"

  # The default is 10 minutes, which a multi-GB SCOS image will not always beat
  # on a home connection.
  upload_timeout = var.scos_image_download_timeout

  # A leftover file from a previous cluster with the same name would otherwise
  # hard-error instead of being replaced.
  overwrite_unmanaged = true
}
