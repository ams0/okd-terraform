terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    # cert-manager still solves its DNS-01 challenge against Azure DNS, and the
    # public A records for api / *.apps stay there too. Proxmox has no DNS of
    # its own, so this is the one piece of Azure the port keeps.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Uploading a file with content_type = "snippets" goes over SSH rather than
  # the REST API, so this block is required even though everything else here
  # is API-driven. Without it, ignition upload fails at apply time.
  ssh {
    agent    = var.proxmox_ssh_agent
    username = var.proxmox_ssh_username
  }
}

provider "azurerm" {
  features {}
}
