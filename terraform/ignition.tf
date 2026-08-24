# Ignition delivery.
#
# Azure capped custom_data at 64 KB, which bootstrap.ign (~330 KB) blows past —
# hence the old SAS-stub dance. master.ign and worker.ign are only ~2 KB each:
# they are Ignition *pointer* configs whose entire job is to merge the real
# config from https://api-int.<domain>:22623/config/<role>.
#
# Proxmox has no size limit, but it also has no native Ignition support: the
# QEMU firmware-config device is the standard channel, and CoreOS reads it from
# `opt/com.coreos/config`.
#
# The config could be passed inline as `-fw_cfg name=...,string=<json>`, which
# is what most Proxmox/CoreOS guides do. That puts the whole ignition on the
# QEMU command line — tolerable for a 2 KB pointer config, hopeless for the
# 330 KB bootstrap.ign. Uploading each ignition as a snippet and pointing
# fw_cfg at the file keeps the command line to one path regardless of size.
#
# Snippet upload goes over SSH (not the REST API) and the snippets content type
# is disabled on fresh Proxmox installs, so both are prerequisites here.

resource "proxmox_virtual_environment_file" "bootstrap_ign" {
  count = local.single_node ? 0 : 1

  node_name    = local.upload_node
  datastore_id = var.proxmox_snippet_datastore
  content_type = "snippets"

  source_raw {
    data      = local.bootstrap_ign
    file_name = "${local.infra_id}-bootstrap.ign"
  }
}

resource "proxmox_virtual_environment_file" "master_ign" {
  node_name    = local.upload_node
  datastore_id = var.proxmox_snippet_datastore
  content_type = "snippets"

  source_raw {
    data      = local.control_plane_ign
    file_name = "${local.infra_id}-master.ign"
  }
}

resource "proxmox_virtual_environment_file" "worker_ign" {
  count = local.worker_count > 0 ? 1 : 0

  node_name    = local.upload_node
  datastore_id = var.proxmox_snippet_datastore
  content_type = "snippets"

  source_raw {
    data      = local.worker_ign
    file_name = "${local.infra_id}-worker.ign"
  }
}

locals {
  # fw_cfg needs an absolute path on the Proxmox host, which the provider does
  # not expose (its `id` is the PVE volume ID, e.g. "local:snippets/x.ign").
  # Build the path from the configured snippets directory instead.
  bootstrap_ign_host_path = "${var.proxmox_snippet_path}/${local.infra_id}-bootstrap.ign"
  master_ign_host_path    = "${var.proxmox_snippet_path}/${local.infra_id}-master.ign"
  worker_ign_host_path    = "${var.proxmox_snippet_path}/${local.infra_id}-worker.ign"

  # Commas are the argument separator in -fw_cfg, so any comma inside the value
  # has to be doubled. Paths shouldn't contain commas, but infra_id is derived
  # from cluster metadata, so escape rather than assume.
  fw_cfg = {
    bootstrap = "-fw_cfg name=opt/com.coreos/config,file=${replace(local.bootstrap_ign_host_path, ",", ",,")}"
    master    = "-fw_cfg name=opt/com.coreos/config,file=${replace(local.master_ign_host_path, ",", ",,")}"
    worker    = "-fw_cfg name=opt/com.coreos/config,file=${replace(local.worker_ign_host_path, ",", ",,")}"
  }
}
