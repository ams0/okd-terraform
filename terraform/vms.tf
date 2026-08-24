# Cluster VMs.
#
# Every VM boots the same SCOS image and is differentiated only by the ignition
# handed to it through the QEMU firmware-config device (see ignition.tf).
#
# Notes that apply to all three roles:
#   - `agent { enabled = false }`: SCOS ships no qemu-guest-agent, and leaving
#     this on makes Terraform block for minutes waiting for an agent that will
#     never answer.
#   - `stop_on_destroy`: without it the provider issues a graceful shutdown and
#     waits; a half-bootstrapped node frequently ignores it, so destroy hangs.
#   - Ignition is NOT attached here. The QEMU `args` option carrying the fw_cfg
#     pointer cannot be set through the Proxmox API by ANY api token: PVE
#     compares the authenticated user against the literal string "root@pam",
#     and for token auth that user is the full token-ID "root@pam!name", which
#     never matches. vm_boot.tf attaches it over SSH and starts the VM, so
#     these are deliberately created stopped.

locals {
  # A freshly imported disk is the image's own size; `size` grows it. The
  # cluster needs materially more than the image provides, and Proxmox can
  # only ever expand, never shrink.
  disk_interface = "virtio0"
}

# ---------------------------------------------------------------------------
# Bootstrap (3-CP mode only — SNO bootstraps in place)
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "bootstrap" {
  count = local.single_node ? 0 : 1

  name      = "${local.infra_id}-bootstrap"
  node_name = local.bootstrap_node
  tags      = concat(local.vm_tags, ["bootstrap"])

  description = "OKD bootstrap node for ${local.cluster_domain}. Safe to delete once the control plane is up."

  agent {
    enabled = false
  }

  cpu {
    cores = var.bootstrap_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.bootstrap_memory_mb
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = proxmox_download_file.scos.id
    interface    = local.disk_interface
    size         = var.bootstrap_disk_gb
  }

  network_device {
    bridge      = var.proxmox_bridge
    mac_address = local.bootstrap_mac
    vlan_id     = var.proxmox_vlan_id
  }

  operating_system {
    type = "l26"
  }

  vm_id = local.bootstrap_vmid

  # Started by vm_boot.tf once its ignition args are attached; booting
  # without them would leave the guest with no configuration at all.
  started = false

  stop_on_destroy = true

  depends_on = [proxmox_virtual_environment_file.bootstrap_ign]
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "master" {
  count = local.master_count

  name      = "${local.infra_id}-master-${count.index}"
  node_name = local.master_nodes[count.index]
  tags      = concat(local.vm_tags, ["master"])

  description = "OKD control plane ${count.index} for ${local.cluster_domain}"

  agent {
    enabled = false
  }

  cpu {
    cores = var.master_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.master_memory_mb
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = proxmox_download_file.scos.id
    interface    = local.disk_interface
    size         = var.master_disk_gb
  }

  network_device {
    bridge      = var.proxmox_bridge
    mac_address = local.master_macs[count.index]
    vlan_id     = var.proxmox_vlan_id
  }

  operating_system {
    type = "l26"
  }

  vm_id = local.master_vmids[count.index]

  # Started by vm_boot.tf once its ignition args are attached; booting
  # without them would leave the guest with no configuration at all.
  started = false

  stop_on_destroy = true

  depends_on = [proxmox_virtual_environment_file.master_ign]
}

# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "worker" {
  count = local.worker_count

  name      = "${local.infra_id}-worker-${count.index}"
  node_name = local.worker_nodes[count.index]
  tags      = concat(local.vm_tags, ["worker"])

  description = "OKD worker ${count.index} for ${local.cluster_domain}"

  agent {
    enabled = false
  }

  cpu {
    cores = var.worker_cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.worker_memory_mb
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = proxmox_download_file.scos.id
    interface    = local.disk_interface
    size         = var.worker_disk_gb
  }

  network_device {
    bridge      = var.proxmox_bridge
    mac_address = local.worker_macs[count.index]
    vlan_id     = var.proxmox_vlan_id
  }

  operating_system {
    type = "l26"
  }

  vm_id = local.worker_vmids[count.index]

  # Started by vm_boot.tf once its ignition args are attached; booting
  # without them would leave the guest with no configuration at all.
  started = false

  stop_on_destroy = true

  depends_on = [proxmox_virtual_environment_file.worker_ign]
}
