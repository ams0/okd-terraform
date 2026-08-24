locals {
  metadata     = jsondecode(file("${path.module}/../install/metadata.json"))
  infra_id     = local.metadata.infraID
  cluster_name = local.metadata.clusterName


  # Proxmox tags are flat strings, not key/value pairs. Render the map as
  # `key-value` and add an ownership tag so a cluster's VMs are greppable.
  # Proxmox lowercases tags and rejects most punctuation, so normalise.
  vm_tags = concat(
    ["okd", lower(local.infra_id)],
    [for k, v in var.tags : lower(replace("${k}-${v}", "/[^A-Za-z0-9-_]/", "-"))]
  )

  master_count = var.master_count
  worker_count = var.worker_count

  # Single Node OpenShift uses bootstrap-in-place (the master self-bootstraps)
  # so there is no bootstrap VM and the master's ignition is the single-node
  # bootstrap-in-place ignition rather than master.ign.
  single_node = var.master_count == 1

  # Router pods (HostNetwork) bind :80/:443 on either workers (when present)
  # or masters (compact mode). keepalived's ingress VIP has to follow the same
  # rule, so the health check below targets whichever role runs the router.
  router_targets_workers = var.worker_count > 0

  # The ignition files only exist in the modes that need them. SNO produces
  # only `bootstrap-in-place-for-live-iso.ign`; HA mode produces master.ign +
  # worker.ign + bootstrap.ign. Use fileexists() so plan doesn't fail when a
  # file is legitimately absent.
  master_ign_path    = "${path.module}/../install/master.ign"
  worker_ign_path    = "${path.module}/../install/worker.ign"
  bootstrap_ign_path = "${path.module}/../install/bootstrap.ign"
  sno_ign_path       = "${path.module}/../install/bootstrap-in-place-for-live-iso.ign"

  master_ign    = fileexists(local.master_ign_path) ? file(local.master_ign_path) : ""
  worker_ign    = fileexists(local.worker_ign_path) ? file(local.worker_ign_path) : ""
  bootstrap_ign = fileexists(local.bootstrap_ign_path) ? file(local.bootstrap_ign_path) : ""
  sno_ign       = fileexists(local.sno_ign_path) ? file(local.sno_ign_path) : ""

  # In SNO mode the single master boots the bootstrap-in-place ignition.
  control_plane_ign = local.single_node ? local.sno_ign : local.master_ign

  # MACs are pinned rather than left to Proxmox so the operator can create
  # matching DHCP reservations once and have them survive destroy/recreate.
  # Layout: <prefix>:<role>:00:<index>, role 00=bootstrap 01=master 02=worker.
  bootstrap_mac = format("%s:00:00:00", var.mac_address_prefix)
  master_macs   = [for i in range(local.master_count) : format("%s:01:00:%02x", var.mac_address_prefix, i)]
  worker_macs   = [for i in range(local.worker_count) : format("%s:02:00:%02x", var.mac_address_prefix, i)]
}
