provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # The provider falls back to SSH for a few operations the REST API does not
  # cover, such as importing disk images. A key file is used rather than an
  # agent because ssh-agent is not reliably running under Git Bash on Windows.
  ssh {
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_file))
  }
}
