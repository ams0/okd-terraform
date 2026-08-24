# Attach ignition to each VM, then start it.
#
# This exists because of a hard Proxmox restriction rather than a preference.
# The QEMU `args` option — which is how the fw_cfg pointer to a node's ignition
# is delivered — is root-only, and "root" means the literal string:
#
#     PVE/API2/Qemu.pm:  } else {
#                            # catches args, lock, etc.
#                            die "only root can set '$opt' config\n";
#                        }
#     ... reached unless $authuser eq 'root@pam'
#
# For API-token auth PVE sets that user to the full token-ID:
#
#     PVE/HTTPServer.pm: # the token-ID `<user>@<realm>!<tokenname>` is the
#                        #  user for token based authentication
#
# so `root@pam!provider` never equals `root@pam`. No API token can set `args`,
# however privileged. The alternatives are username/password auth as root@pam —
# putting the host root password in tfvars — or doing it outside the API. We
# already require SSH for snippet upload, so this uses that instead and the
# token stays unprivileged.
#
# The VMs are created stopped (see vms.tf) because a guest booted without its
# ignition has no configuration at all and would have to be rebuilt.

locals {
  # ssh options: IdentityAgent=none matters. If a stale agent is present, ssh
  # tries it for this key and fails the handshake outright rather than falling
  # back to the key file.
  ssh_opts = join(" ", [
    "-i ${pathexpand(var.proxmox_ssh_private_key_file)}",
    "-o IdentityAgent=none",
    "-o IdentitiesOnly=yes",
    "-o StrictHostKeyChecking=accept-new",
    "-o BatchMode=yes",
    "-o ConnectTimeout=15",
  ])

  # `qm` only manages guests on the node it runs on, so each VM is configured
  # from its own hypervisor. --args= (rather than --args ) keeps Getopt from
  # reading the leading dash of -fw_cfg as another option.
  boot_cmd = "qm set %s --args='%s' && qm start %s"
}

resource "null_resource" "bootstrap_boot" {
  count = local.single_node ? 0 : 1

  triggers = {
    vmid = local.bootstrap_vmid
    args = local.fw_cfg.bootstrap
    # so replacing the VM re-attaches ignition instead of leaving it stopped
    vm   = proxmox_virtual_environment_vm.bootstrap[0].id
    host = var.proxmox_node_hosts[local.bootstrap_node]
  }

  provisioner "local-exec" {
    command = "ssh ${local.ssh_opts} root@${var.proxmox_node_hosts[local.bootstrap_node]} ${format("\"${local.boot_cmd}\"", local.bootstrap_vmid, local.fw_cfg.bootstrap, local.bootstrap_vmid)}"
  }

  depends_on = [proxmox_virtual_environment_vm.bootstrap]
}

resource "null_resource" "master_boot" {
  count = local.master_count

  triggers = {
    vmid = local.master_vmids[count.index]
    args = local.fw_cfg.master
    # so replacing the VM re-attaches ignition instead of leaving it stopped
    vm   = proxmox_virtual_environment_vm.master[count.index].id
    host = var.proxmox_node_hosts[local.master_nodes[count.index]]
  }

  provisioner "local-exec" {
    command = "ssh ${local.ssh_opts} root@${var.proxmox_node_hosts[local.master_nodes[count.index]]} ${format("\"${local.boot_cmd}\"", local.master_vmids[count.index], local.fw_cfg.master, local.master_vmids[count.index])}"
  }

  # Masters must not start before the bootstrap node is up: their ignition is a
  # pointer that fetches the real config from api-int:22623, which only
  # bootstrap serves at this stage.
  depends_on = [
    proxmox_virtual_environment_vm.master,
    null_resource.bootstrap_boot,
  ]
}

resource "null_resource" "worker_boot" {
  count = local.worker_count

  triggers = {
    vmid = local.worker_vmids[count.index]
    args = local.fw_cfg.worker
    # so replacing the VM re-attaches ignition instead of leaving it stopped
    vm   = proxmox_virtual_environment_vm.worker[count.index].id
    host = var.proxmox_node_hosts[local.worker_nodes[count.index]]
  }

  provisioner "local-exec" {
    command = "ssh ${local.ssh_opts} root@${var.proxmox_node_hosts[local.worker_nodes[count.index]]} ${format("\"${local.boot_cmd}\"", local.worker_vmids[count.index], local.fw_cfg.worker, local.worker_vmids[count.index])}"
  }

  depends_on = [
    proxmox_virtual_environment_vm.worker,
    null_resource.bootstrap_boot,
  ]
}
