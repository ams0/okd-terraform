variable "location" {
  description = "Azure region for the cluster"
  type        = string
  default     = "francecentral"
}

variable "base_domain" {
  description = "Public DNS zone name (parent of the cluster's FQDNs)"
  type        = string
  default     = "techmasters.cloud"
}

variable "dns_zone_resource_group" {
  description = "Resource group hosting the public Azure DNS zone for base_domain"
  type        = string
  default     = "resources"
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt account (used by cert-manager ACME)"
  type        = string
  default     = "alessandro@stackmasters.com"
}

variable "cert_manager_azure_client_id" {
  description = "Service Principal app (client) ID with DNS Zone Contributor on the public DNS zone"
  type        = string
}

variable "cert_manager_azure_client_secret" {
  description = "Service Principal client secret"
  type        = string
  sensitive   = true
}

variable "cert_manager_azure_tenant_id" {
  description = "Azure AD tenant ID for the cert-manager SP"
  type        = string
}

variable "cert_manager_azure_subscription_id" {
  description = "Azure subscription ID hosting the public DNS zone"
  type        = string
}

variable "master_count" {
  description = "Number of control-plane VMs. 1 = Single Node OpenShift (bootstrap-in-place, no bootstrap VM). 3 = HA control plane (standard UPI bootstrap)."
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3], var.master_count)
    error_message = "master_count must be 1 or 3."
  }
}

variable "worker_count" {
  description = "Number of worker VMs. 0 = compact / SNO mode (router pods run on masters via HostNetwork). >0 = router pods run on workers (requires master_count=3 because SNO does not produce a worker.ign)."
  type        = number
  default     = 0
  validation {
    condition     = var.worker_count >= 0
    error_message = "worker_count must be >= 0."
  }
}

# Cross-variable check: SNO can't have workers (single-node-ignition-config
# doesn't produce a worker.ign).
check "sno_no_workers" {
  assert {
    condition     = !(var.master_count == 1 && var.worker_count > 0)
    error_message = "master_count=1 (Single Node OpenShift) requires worker_count=0. Use master_count=3 for clusters with workers."
  }
}

variable "master_vm_size" {
  description = "Azure VM size for control-plane VMs"
  type        = string
  default     = "Standard_D8s_v3"
}

variable "worker_vm_size" {
  description = "Azure VM size for worker VMs (when worker_count > 0)"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "bootstrap_vm_size" {
  description = "Azure VM size for the temporary bootstrap node (3-CP mode only; ignored for SNO)"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "scos_vhd_blob_uri" {
  description = "Full HTTPS URI of the pre-uploaded SCOS Azure VHD page blob"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key embedded in the cluster (already in master.ign, repeated here for the Azure VM admin_ssh_key block)"
  type        = string
}

variable "tags" {
  description = "Extra tags applied to every resource (the cluster ownership tag is added automatically)"
  type        = map(string)
  default = {
    SecurityControl = "Ignore"
    CostControl     = "Ignore"
    owner           = "alessandro"
  }
}
