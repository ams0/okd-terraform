locals {
  metadata     = jsondecode(file("${path.module}/../install/metadata.json"))
  infra_id     = local.metadata.infraID
  cluster_name = local.metadata.clusterName

  cluster_tag = {
    "kubernetes.io_cluster.${local.infra_id}" = "owned"
  }
  base_tags = merge(var.tags, local.cluster_tag)

  vnet_cidr     = "10.0.0.0/16"
  master_subnet = "10.0.0.0/24"
  worker_subnet = "10.0.1.0/24"

  master_count = var.master_count
  worker_count = var.worker_count

  # Single Node OpenShift uses bootstrap-in-place (the master self-bootstraps)
  # so there is no bootstrap VM and the master's ignition is the single-node
  # bootstrap-in-place ignition rather than master.ign.
  single_node = var.master_count == 1

  # Router pods (HostNetwork) bind :80/:443 on either workers (when present)
  # or masters (compact mode). The router LB backend pool follows.
  router_targets_workers = var.worker_count > 0

  # The ignition files only exist in the modes that need them. SNO produces
  # only `bootstrap-in-place-for-live-iso.ign`; HA mode produces master.ign +
  # worker.ign + bootstrap.ign. Use fileexists() so plan doesn't fail when a
  # file is legitimately absent.
  master_ign_path = "${path.module}/../install/master.ign"
  worker_ign_path = "${path.module}/../install/worker.ign"
  master_ign      = fileexists(local.master_ign_path) ? file(local.master_ign_path) : ""
  worker_ign      = fileexists(local.worker_ign_path) ? file(local.worker_ign_path) : ""
}

resource "azurerm_resource_group" "main" {
  name     = "${local.infra_id}-rg"
  location = var.location
  tags     = local.base_tags
}
