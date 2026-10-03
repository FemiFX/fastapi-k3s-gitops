variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, including scheme and port."
  type        = string
  default     = "https://203.0.113.10:8006/"
}

variable "proxmox_node" {
  description = "Name of the Proxmox node that will host the VMs."
  type        = string
  default     = "sept25-continu-en-femi-fastapi-traefik"
}

variable "proxmox_api_token" {
  description = <<-EOT
    Proxmox API token in the form 'user@realm!tokenid=secret'.
    Never commit this. Supply it through a gitignored terraform.tfvars or the
    TF_VAR_proxmox_api_token environment variable.
  EOT
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification. Proxmox ships a self-signed certificate."
  type        = bool
  default     = true
}

variable "vm_datastore" {
  description = "Storage pool for VM disks. vmdata is the 5.25 TB ZFS pool."
  type        = string
  default     = "vmdata"
}

variable "template_vm_id" {
  description = "VMID of the cloud-init template that VMs are cloned from."
  type        = number
  default     = 9000
}

variable "network_bridge" {
  description = <<-EOT
    Bridge the VMs attach to. vmbr1 is the private NAT bridge created by
    infra/scripts/host-network.sh. The VMs cannot use vmbr0 because the
    provider only leases public addresses to the host's registered MAC.
  EOT
  type        = string
  default     = "vmbr1"
}

variable "network_gateway" {
  description = "Gateway for the private network (the host's vmbr1 address)."
  type        = string
  default     = "10.10.10.1"
}

variable "network_cidr_suffix" {
  description = "Prefix length for the private network."
  type        = number
  default     = 24
}

variable "nameserver" {
  description = "DNS resolver for the VMs (the provider's resolver)."
  type        = string
  default     = "51.159.47.26"
}

variable "vm_username" {
  description = "Login account created on each VM by cloud-init."
  type        = string
  default     = "femi"
}

variable "vms" {
  description = <<-EOT
    The virtual machines to create. Sizing is constrained by the node's 8 vCPU;
    RAM (94 GB) and disk (5.25 TB) are not constraints.
  EOT
  type = map(object({
    vm_id       = number
    cores       = number
    memory_mb   = number
    disk_gb     = number
    ip_address  = string
    description = string
  }))

  default = {
    ci-runner = {
      vm_id       = 201
      cores       = 2
      memory_mb   = 4096
      disk_gb     = 40
      ip_address  = "10.10.10.10"
      description = "Self-hosted GitLab Runner"
    }
    staging = {
      vm_id       = 202
      cores       = 2
      memory_mb   = 6144
      disk_gb     = 40
      ip_address  = "10.10.10.20"
      description = "k3s single node - staging environment"
    }
    prod-server = {
      vm_id       = 203
      cores       = 2
      memory_mb   = 6144
      disk_gb     = 40
      ip_address  = "10.10.10.30"
      description = "k3s control plane - production environment"
    }
    prod-agent = {
      vm_id       = 204
      cores       = 2
      memory_mb   = 4096
      disk_gb     = 40
      ip_address  = "10.10.10.31"
      description = "k3s agent - production environment"
    }
  }
}

variable "proxmox_ssh_private_key_file" {
  description = <<-EOT
    Path to the private key used for the provider's SSH fallback connection to
    the Proxmox host. The matching public key must be in the host's
    /root/.ssh/authorized_keys (see infra/README.md).
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519"
}
