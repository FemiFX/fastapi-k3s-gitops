# Infrastructure

Infrastructure as Code for the Proxmox environment: four virtual machines
hosting the CI runner and the staging and production k3s clusters.

## Layout

```
infra/
├── scripts/
│   ├── host-network.sh     # one-off: private NAT bridge on the Proxmox host
│   └── build-template.sh   # one-off: cloud-init VM template Terraform clones
└── terraform/
    ├── versions.tf         # Terraform and provider versions
    ├── providers.tf        # Proxmox provider configuration
    ├── variables.tf        # all inputs, including VM sizing
    ├── main.tf             # the VMs
    ├── outputs.tf          # addresses and SSH commands
    └── terraform.tfvars.example
```

## Target topology

The host has a single public IP, and the hosting provider leases addresses only
to the server's registered MAC, so VMs live on a private bridge behind NAT.

| VM | vCPU | RAM | Disk | Address | Role |
| --- | --- | --- | --- | --- | --- |
| `ci-runner` | 2 | 4 GB | 40 GB | 10.10.10.10 | Self-hosted GitLab Runner |
| `staging` | 2 | 6 GB | 40 GB | 10.10.10.20 | k3s single node, staging |
| `prod-server` | 2 | 6 GB | 40 GB | 10.10.10.30 | k3s control plane, production |
| `prod-agent` | 2 | 4 GB | 40 GB | 10.10.10.31 | k3s agent, production |

Inbound ports 80 and 443 are forwarded from the public IP to `prod-server`.
Staging is deliberately not exposed and is reached through the host.

## Prerequisites

1. **A Proxmox API token for a dedicated, least-privilege user.** Automation
   never uses root.

   ```sh
   pveum user add terraform@pve
   pveum role add TerraformProv -privs "Datastore.AllocateSpace Datastore.Audit \
     SDN.Use Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone \
     VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk \
     VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
     VM.Migrate VM.Monitor VM.PowerMgmt"
   pveum acl modify / -user terraform@pve -role TerraformProv
   pveum user token add terraform@pve provider --privsep 0
   ```

   `--privsep 0` matters: with privilege separation on, the token starts with no
   privileges regardless of the user's role.

2. **The host network bridge and the VM template**, both run once on the host:

   ```sh
   ./host-network.sh
   ./build-template.sh
   ```

## Usage

```sh
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # then fill it in (gitignored)

terraform init
terraform plan      # review before changing anything
terraform apply
```

## Secrets

`terraform.tfvars` and `*.tfstate` are gitignored. State can contain sensitive
values and is the record of what really exists. In CI the token is supplied as
`TF_VAR_proxmox_api_token` from a repository secret.

## Known limitations

- **Local state.** Adequate for a single operator; a remote backend with locking
  would be required for a team or for applying from CI.
- **Single Proxmox node.** No hypervisor-level high availability is possible;
  redundancy exists only at the Kubernetes layer.
- **The template is built by a script, not Packer.** Version-controlled and
  documented, but not itself declarative.
