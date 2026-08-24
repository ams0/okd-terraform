# SCOS node image.
#
# On Azure this was an azurerm_image built from a VHD page blob the operator
# had to stage by hand. Proxmox pulls the image itself through the PVE
# download-url API, so it lands straight on the node and never transits the
# machine running Terraform.
#
# SCOS publishes the qemu artifact gzipped (scos-<build>-qemu.x86_64.qcow2.gz),
# which dictates the shape of this resource:
#
#   - content_type must be `iso`, not `import`. The provider only accepts
#     `import_from` for uncompressed images; a file downloaded with
#     decompression_algorithm set has to be referenced via `disk.file_id`
#     instead (see vms.tf). `iso` is enabled by default on PVE storages, so
#     this also removes a manual prerequisite.
#   - file_name has to end in .img. PVE rejects a bare .qcow2 extension for
#     iso content on versions before 8.4.
#
# Get the URL and checksum for the release you are installing with:
#     .bin/openshift-install coreos print-stream-json \
#       | jq -r '.architectures.x86_64.artifacts.qemu.formats["qcow2.gz"].disk'
#
# The API token needs Datastore.AllocateTemplate plus Sys.Audit and Sys.Modify.
resource "proxmox_download_file" "scos" {
  node_name    = var.proxmox_node
  datastore_id = var.proxmox_iso_datastore
  content_type = "iso"

  url                     = var.scos_image_url
  checksum                = var.scos_image_checksum
  checksum_algorithm      = var.scos_image_checksum == null ? null : var.scos_image_checksum_algorithm
  decompression_algorithm = var.scos_image_decompression

  # Stable name so re-applies reuse the existing download instead of re-pulling
  # several GB. Scoped by infra_id so two clusters never collide.
  file_name = "scos-${local.infra_id}.qcow2.img"

  # The default is 10 minutes, which a multi-GB image will not always beat on a
  # home connection — and this one is decompressed on the node as well.
  upload_timeout = var.scos_image_download_timeout

  # A leftover file from a previous cluster with the same name would otherwise
  # hard-error instead of being replaced.
  overwrite_unmanaged = true
}
