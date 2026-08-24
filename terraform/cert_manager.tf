############################
# Render cert-manager manifests with cluster-specific values
############################

locals {
  cert_manager_dir           = "${path.module}/../cert-manager"
  cert_manager_manifests_dir = "${path.module}/../cert-manager/rendered"
  # Derived from install metadata rather than hardcoded, so it cannot drift
  # from the DNS records in dns_public.tf if the cluster is ever renamed.
  cluster_domain = "${local.cluster_name}.${var.base_domain}"
}

resource "local_file" "azure_dns_secret" {
  filename = "${local.cert_manager_manifests_dir}/02-azure-dns-secret.yaml"
  content = templatefile("${local.cert_manager_dir}/templates/02-azure-dns-secret.yaml.tpl", {
    client_secret = var.cert_manager_azure_client_secret
  })
  file_permission = "0600"
}

resource "local_file" "cluster_issuer" {
  filename = "${local.cert_manager_manifests_dir}/03-cluster-issuer.yaml"
  content = templatefile("${local.cert_manager_dir}/templates/03-cluster-issuer.yaml.tpl", {
    email           = var.letsencrypt_email
    client_id       = var.cert_manager_azure_client_id
    subscription_id = var.cert_manager_azure_subscription_id
    tenant_id       = var.cert_manager_azure_tenant_id
    dns_rg          = var.dns_zone_resource_group
    zone_name       = var.base_domain
  })
  file_permission = "0644"
}

resource "local_file" "apps_wildcard_cert" {
  filename = "${local.cert_manager_manifests_dir}/04-apps-wildcard-cert.yaml"
  content = templatefile("${local.cert_manager_dir}/templates/04-apps-wildcard-cert.yaml.tpl", {
    cluster_domain = local.cluster_domain
  })
  file_permission = "0644"
}

resource "local_file" "ingress_controller" {
  filename = "${local.cert_manager_manifests_dir}/05-ingress-controller.yaml"
  content = templatefile("${local.cert_manager_dir}/templates/05-ingress-controller.yaml.tpl", {
    cluster_domain = local.cluster_domain
    target_role    = local.router_targets_workers ? "worker" : "master"
    replicas       = local.router_targets_workers ? min(local.worker_count, 3) : local.master_count
  })
  file_permission = "0644"
}

# Symlink the static cert-manager bundle into the rendered dir so apply.sh sees
# all four files in one place.
resource "null_resource" "cert_manager_bundle_link" {
  triggers = {
    rendered_dir = local.cert_manager_manifests_dir
  }
  provisioner "local-exec" {
    command = "mkdir -p '${local.cert_manager_manifests_dir}' && ln -sf '../01-cert-manager.yaml' '${local.cert_manager_manifests_dir}/01-cert-manager.yaml'"
  }
}

############################
# Apply cert-manager + Issuer + Certificate + IngressController patch
############################

resource "null_resource" "cert_manager_apply" {
  # Re-run when any source manifest, rendered manifest, or apply script changes.
  triggers = {
    bundle      = filesha256("${local.cert_manager_dir}/01-cert-manager.yaml")
    secret_tpl  = filesha256("${local.cert_manager_dir}/templates/02-azure-dns-secret.yaml.tpl")
    issuer_tpl  = filesha256("${local.cert_manager_dir}/templates/03-cluster-issuer.yaml.tpl")
    cert_tpl    = filesha256("${local.cert_manager_dir}/templates/04-apps-wildcard-cert.yaml.tpl")
    ingress_tpl = filesha256("${local.cert_manager_dir}/templates/05-ingress-controller.yaml.tpl")
    apply_sh    = filesha256("${local.cert_manager_dir}/scripts/apply.sh")
    secret_hash = sha256(var.cert_manager_azure_client_secret)
    cluster_id  = local.infra_id
  }

  provisioner "local-exec" {
    working_dir = path.module
    environment = {
      KUBECONFIG     = "${path.module}/../install/auth/kubeconfig"
      MANIFEST_DIR   = local.cert_manager_manifests_dir
      CLUSTER_DOMAIN = local.cluster_domain
    }
    command = "${local.cert_manager_dir}/scripts/apply.sh"
  }

  depends_on = [
    local_file.azure_dns_secret,
    local_file.cluster_issuer,
    local_file.apps_wildcard_cert,
    local_file.ingress_controller,
    null_resource.cert_manager_bundle_link,
    azurerm_dns_a_record.api,
    azurerm_dns_a_record.apps,
    # The VMs no longer sit behind a cloud LB whose creation implied the nodes
    # existed, so depend on them directly. apply.sh still waits for the API
    # itself, but without this the provisioner can start before a single node
    # has been defined.
    proxmox_virtual_environment_vm.master,
  ]
}
