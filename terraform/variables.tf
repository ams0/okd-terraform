# ---------------------------------------------------------------------------
# Proxmox connection
# ---------------------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve.lan:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in `user@realm!tokenid=uuid` form. Needs VM.* plus Datastore.AllocateTemplate, Sys.Audit and Sys.Modify (the latter two for image download)."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification against the Proxmox API (true for the default self-signed certificate)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox node. Snippet upload (the ignition files) goes over SSH, not the REST API, so this must be able to write to the snippets datastore."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_private_key_file" {
  description = "Path to a private key that can SSH into every node in proxmox_nodes. Snippet upload runs over SSH, and with API-token auth the provider cannot inherit a credential from the token, so either this or proxmox_ssh_agent must be set. Note the provider parses the key itself: if an OPENSSH-format key is rejected, convert a copy with `ssh-keygen -p -m PEM -f <copy>`."
  type        = string
  default     = null
}

variable "proxmox_ssh_agent" {
  description = "Fall back to the local SSH agent instead of proxmox_ssh_private_key_file. Ignored when a key file is given."
  type        = bool
  default     = false
}

check "ssh_credential_present" {
  assert {
    condition     = var.proxmox_ssh_private_key_file != null || var.proxmox_ssh_agent
    error_message = "Snippet upload needs SSH: set proxmox_ssh_private_key_file, or enable proxmox_ssh_agent with the key loaded."
  }
}

variable "proxmox_nodes" {
  description = "Proxmox nodes to spread cluster VMs across, in placement order (e.g. [\"pve1\",\"pve2\",\"pve3\"]). Masters and workers are assigned round-robin so losing one hypervisor cannot take out the whole control plane. A single-element list pins everything to one node."
  type        = list(string)
  validation {
    condition     = length(var.proxmox_nodes) > 0
    error_message = "proxmox_nodes must contain at least one node name."
  }
}

variable "proxmox_node_hosts" {
  description = "Map of Proxmox node name to an address Terraform can SSH into, e.g. {pve1 = \"172.29.1.11\"}. Needed because the QEMU `args` option cannot be set through the API by any token (see vm_boot.tf), so it is applied with `qm set` on the node itself."
  type        = map(string)
}

variable "vm_id_base" {
  description = "First VMID to allocate. IDs are assigned deterministically (base+0 bootstrap, base+1.. masters, base+10.. workers) rather than via cluster/nextid, which races and times out when several VMs are created at once."
  type        = number
  default     = 9000
}

variable "proxmox_datastore" {
  description = "Datastore for VM disks. Prefer a shared store (Ceph RBD) so masters can live-migrate between hypervisors; a node-local store also works but pins each VM to its node. There is no universal default -- `local-lvm` does not exist on every cluster -- so set this explicitly."
  type        = string
}

variable "proxmox_iso_datastore" {
  description = "Datastore holding the downloaded SCOS image, using the `iso` content type. MUST be shared across nodes (e.g. CephFS) when proxmox_nodes has more than one entry — the image is downloaded once and every node has to be able to read it."
  type        = string
  default     = "local"
}

variable "proxmox_snippet_datastore" {
  description = "Datastore holding the uploaded ignition snippets. Snippets are NOT enabled by default — turn them on under Datacenter > Storage first. MUST be shared (CephFS) when spreading across nodes, and must be filesystem-backed: Ceph RBD cannot hold snippets, only CephFS can."
  type        = string
  default     = "local"
}

variable "proxmox_snippet_path" {
  description = "Absolute path to the snippets directory on the Proxmox host, used to build the fw_cfg file= argument. Must match proxmox_snippet_datastore: the built-in `local` store is /var/lib/vz/snippets; every mounted store (CephFS, NFS, directory) is /mnt/pve/<storage-id>/snippets. Confirm with `pvesm status` on a node."
  type        = string
  default     = "/var/lib/vz/snippets"
}

variable "proxmox_bridge" {
  description = "Bridge or SDN VNet the VMs attach to. An SDN VNet (e.g. vmnet34) will not appear in `pvesh get /nodes/<node>/network` -- check `pvesh get /cluster/sdn/vnets`. If the VNet already carries a VLAN tag, leave proxmox_vlan_id unset."
  type        = string
  default     = "vmbr0"
}

variable "proxmox_vlan_id" {
  description = "Optional VLAN tag for the VM NICs. null = untagged."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Cluster networking
# ---------------------------------------------------------------------------

variable "machine_network_cidr" {
  description = "CIDR of the subnet the nodes sit on. Must match the network the Proxmox bridge is attached to, and is what openshift-install records as the machine network."
  type        = string
}

variable "api_vip" {
  description = "Free IP on machine_network_cidr for the API VIP (:6443). Held by keepalived on whichever control-plane node wins the VRRP election."
  type        = string
}

variable "ingress_vip" {
  description = "Free IP on machine_network_cidr for the ingress VIP (:80/:443). Must differ from api_vip."
  type        = string
}

variable "vrrp_interface_bootstrap" {
  description = "Interface keepalived binds the API VIP to on the BOOTSTRAP node. Bootstrap runs no OVN, so this is the raw NIC — SCOS on Proxmox with a virtio NIC gets `ens18`."
  type        = string
  default     = "ens18"
}

variable "vrrp_interface_node" {
  description = "Interface keepalived binds the VIPs to on CLUSTER nodes. OVN-Kubernetes moves the node IP off the physical NIC onto the OVS bridge `br-ex`, so a VIP placed on ens18 there is unreachable. Verify with `ip -br addr` on a joined node."
  type        = string
  default     = "br-ex"
}

variable "vrrp_router_id_api" {
  description = "VRRP virtual_router_id for the API VIP. Must be unique per VRRP domain (i.e. per L2 segment)."
  type        = number
  default     = 51
}

variable "vrrp_router_id_ingress" {
  description = "VRRP virtual_router_id for the ingress VIP"
  type        = number
  default     = 52
}

check "vips_differ" {
  assert {
    condition     = var.api_vip != var.ingress_vip
    error_message = "api_vip and ingress_vip must be different addresses."
  }
}

check "vrrp_ids_differ" {
  assert {
    condition     = var.vrrp_router_id_api != var.vrrp_router_id_ingress
    error_message = "vrrp_router_id_api and vrrp_router_id_ingress must differ, or keepalived will treat both VIPs as one group."
  }
}

# ---------------------------------------------------------------------------
# Node image
# ---------------------------------------------------------------------------

variable "scos_image_url" {
  description = "URL of the SCOS qcow2 to download onto the Proxmox node. Should match the openshift-install release in .bin/."
  type        = string
}

variable "scos_image_checksum" {
  description = "Checksum of scos_image_url (see scos_image_checksum_algorithm). Leave null to skip verification."
  type        = string
  default     = null
}

variable "scos_image_checksum_algorithm" {
  description = "Algorithm for scos_image_checksum (md5, sha1, sha224, sha256, sha384, sha512)"
  type        = string
  default     = "sha256"
}

variable "scos_image_decompression" {
  description = "Decompression applied to scos_image_url on the node. SCOS ships the qemu artifact as .qcow2.gz, so this is `gz`. Set to null for an already-uncompressed image."
  type        = string
  default     = "gz"
}

variable "scos_image_download_timeout" {
  description = "Seconds allowed for the Proxmox node to download the SCOS image. The provider default is 600, which a multi-GB image on a slow link can exceed."
  type        = number
  default     = 3600
}

# ---------------------------------------------------------------------------
# Topology
# ---------------------------------------------------------------------------

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

variable "master_cpu_cores" {
  description = "vCPU cores per control-plane VM"
  type        = number
  default     = 8
}

variable "master_memory_mb" {
  description = "RAM per control-plane VM in MiB"
  type        = number
  default     = 32768
}

variable "master_disk_gb" {
  description = "Root disk size per control-plane VM in GiB"
  type        = number
  default     = 120
}

variable "worker_cpu_cores" {
  description = "vCPU cores per worker VM"
  type        = number
  default     = 4
}

variable "worker_memory_mb" {
  description = "RAM per worker VM in MiB"
  type        = number
  default     = 16384
}

variable "worker_disk_gb" {
  description = "Root disk size per worker VM in GiB"
  type        = number
  default     = 120
}

variable "bootstrap_cpu_cores" {
  description = "vCPU cores for the temporary bootstrap VM (3-CP mode only; ignored for SNO)"
  type        = number
  default     = 4
}

variable "bootstrap_memory_mb" {
  description = "RAM for the temporary bootstrap VM in MiB"
  type        = number
  default     = 16384
}

variable "bootstrap_disk_gb" {
  description = "Root disk size for the temporary bootstrap VM in GiB"
  type        = number
  default     = 120
}

variable "mac_address_prefix" {
  description = "First three octets of the generated MAC addresses. Terraform pins MACs so you can create matching DHCP reservations; the last three octets are derived per role and index."
  type        = string
  default     = "02:00:00"
}

# ---------------------------------------------------------------------------
# DNS (still Azure) and cert-manager
# ---------------------------------------------------------------------------

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

variable "ssh_public_key" {
  description = "SSH public key embedded in the cluster via install-config (repeated here for reference in outputs)"
  type        = string
}

variable "tags" {
  description = "Free-form tags applied to Proxmox VMs (Proxmox tags are flat strings, so these are rendered as `key-value`)"
  type        = map(string)
  default = {
    owner = "alessandro"
  }
}
