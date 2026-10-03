terraform {
  required_version = ">= 1.6"

  required_providers {
    # bpg/proxmox is the actively maintained Proxmox provider and has first
    # class cloud-init and API-token support. telmate/proxmox is the older,
    # less complete alternative.
    # Pinned to the minor version this configuration was validated against.
    # The provider is pre-1.0, so minor releases can still break.
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }

  # State lives in GitLab, not on a laptop.
  #
  # A CI runner is disposable, so local state cannot work from a pipeline: the
  # next run would start with no knowledge of what exists and try to build it
  # all again. Worse, two runs at once would each believe they owned the world.
  # GitLab's state backend also gives locking, so a second apply waits instead
  # of corrupting the first.
  #
  # Deliberately empty here. Every value is supplied through TF_HTTP_*
  # environment variables, so the same configuration works from CI (which
  # authenticates with CI_JOB_TOKEN) and from a workstation (a personal access
  # token), with no per-environment file to keep in sync. See infra/README.md.
  backend "http" {}
}
