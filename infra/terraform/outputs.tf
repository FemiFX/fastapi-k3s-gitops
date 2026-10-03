output "vm_addresses" {
  description = "Private address of each VM, for the Ansible inventory."
  value       = { for name, cfg in var.vms : name => cfg.ip_address }
}

output "vm_ids" {
  description = "Proxmox VMID of each VM."
  value       = { for name, vm in proxmox_virtual_environment_vm.vm : name => vm.vm_id }
}

output "ssh_via_host" {
  description = "How to reach each VM, which is only possible through the Proxmox host."
  value = {
    for name, cfg in var.vms :
    name => "ssh -J <proxmox-ssh-user>@203.0.113.10 ${var.vm_username}@${cfg.ip_address}"
  }
}
