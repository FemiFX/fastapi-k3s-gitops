locals {
  # Every public key in infra/ssh-keys is authorised on every VM.
  #
  # Public keys are public, so they live in the repository rather than in
  # variables that have to be passed identically to Terraform and to Ansible
  # and kept in step by hand. Ansible reads the same directory, so the two can
  # never disagree, and adding a person is dropping in a file rather than
  # editing two tools and a pipeline.
  ssh_keys_dir = "${path.module}/../ssh-keys"

  # trimspace matters: a key file written on Windows ends with a carriage
  # return, which would otherwise be part of the key and show up as a change on
  # every plan.
  ssh_public_keys = sort([
    for f in fileset(local.ssh_keys_dir, "*.pub") :
    trimspace(file("${local.ssh_keys_dir}/${f}"))
  ])
}

# One VM per entry in var.vms, cloned from the cloud-init template built by
# infra/scripts/build-template.sh. Terraform owns the existence and shape of
# the machines; Ansible owns what is installed on them.

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name        = each.key
  description = each.value.description
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id
  tags        = ["terraform", "weiterbildung"]

  # Linked clone: on ZFS this is a copy-on-write snapshot, so creation is
  # near instant and costs almost no space until the VM writes.
  clone {
    vm_id = var.template_vm_id
    full  = false
  }

  agent {
    # The QEMU guest agent is installed by cloud-init. It lets Proxmox report
    # the VM's real IP addresses and shut down guests cleanly.
    enabled = true
  }

  cpu {
    cores = each.value.cores
    # 'host' passes the physical CPU features through, which k3s benefits from.
    type = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_gb
    # Cloud images ship small; cloud-init grows the filesystem to fill this.
  }

  network_device {
    bridge = var.network_bridge
  }

  # cloud-init: the handoff from infrastructure to configuration. It gives the
  # VM a user, an SSH key and a static address so Ansible has a way in.
  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip_address}/${var.network_cidr_suffix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.nameserver]
    }

    user_account {
      username = var.vm_username
      # compact() drops the empty string, so a workstation apply that sets no
      # CI key produces one key rather than one key and a blank entry.
      # sorted and compacted, so an added comment or a blank file does not
      # show up as a change to every VM on the next plan.
      keys = compact(local.ssh_public_keys)
    }
  }

  # Serial console: cloud images expect one, and without it the Proxmox console
  # shows nothing at all.
  serial_device {}

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      # The template may be rebuilt with a newer base image; that must not
      # silently destroy and recreate running VMs.
      clone,
    ]
  }
}
