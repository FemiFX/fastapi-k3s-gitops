# Infrastructure

## Purpose

The infrastructure layer creates the machines and configures the software that
runs the application. Terraform owns the existence and shape of Proxmox VMs.
Ansible owns the operating system, k3s, GitLab components, network controls,
certificates, and monitoring.

The detailed implementation references are:

- [Proxmox and Terraform](../infra/README.md);
- [Ansible](../infra/ansible/README.md);
- [Helm chart](../helm/README.md).

## Proxmox topology

| VM | Address | vCPU | Memory | Disk | Role |
| --- | --- | --- | --- | --- | --- |
| ci-runner | 10.10.10.10 | 2 | 4 GiB | 40 GiB | Self-hosted GitLab Runner |
| staging | 10.10.10.20 | 2 | 6 GiB | 40 GiB | Single-node staging k3s |
| prod-server | 10.10.10.30 | 2 | 6 GiB | 40 GiB | Production k3s control plane |
| prod-agent | 10.10.10.31 | 2 | 4 GiB | 40 GiB | Production k3s worker |

The VMs attach to the private vmbr1 bridge. The Proxmox host provides the
10.10.10.1 gateway, outbound masquerading, and public port forwarding.

## Provisioning sequence

The host network bridge and cloud-init template are one-time host operations.
They are represented by scripts because Terraform clones the template rather
than building the operating-system image itself.

The normal sequence is:

1. create the private host bridge with host-network.sh;
2. create the Ubuntu cloud-init template with build-template.sh;
3. create a Terraform variable file from terraform.tfvars.example;
4. run terraform init;
5. review terraform plan;
6. apply Terraform;
7. verify the VMs answer through the SSH jump host;
8. run the Ansible common and k3s roles;
9. install the GitLab Runner and Agents;
10. apply the firewall configuration after reviewing the compiled rules;
11. install cert-manager;
12. install monitoring;
13. deploy the application from GitLab CI.

## Terraform responsibilities

Terraform creates linked-clone VMs from the cloud-init template. It sets:

- VM IDs and names;
- CPU and memory;
- disks and storage;
- private network attachment;
- static addresses and gateway;
- DNS resolver;
- cloud-init username and SSH key;
- QEMU guest agent;
- serial console.

Terraform state is local and ignored by Git. State can contain sensitive
values and is the record of the infrastructure Terraform believes it owns.

## Ansible responsibilities

The roles are:

| Role | Responsibility |
| --- | --- |
| common | Packages, hostname, clock sync, guest agent, security updates, SSH hardening |
| k3s_server | k3s control plane, Traefik configuration, kubeconfig export |
| k3s_agent | Joins the production worker to the production cluster |
| gitlab_runner | Docker, kubectl, Helm, and the self-hosted GitLab Runner |
| gitlab_agent | GitLab Agent installation, namespace creation, and scoped RBAC |
| proxmox_firewall | Default-deny firewall and public port forwarding |
| cert_manager | cert-manager, ACME issuers, and production DNS rewrite |
| monitoring | kube-prometheus-stack, ServiceMonitor, PrometheusRule, and checks |

Roles tagged never are intentionally run one component at a time because they
need sensitive values or can affect access to the host.

## Network and firewall

Only the Proxmox host has a public address. Public HTTP and HTTPS traffic is
forwarded to the production server. Staging and the other VMs remain on the
private network.

The firewall role writes and displays its rules while disabled. It only enables
the firewall when firewall_enable=true is passed. This two-step process reduces
the chance of locking out the operator while changing remote access rules.

## Certificates

cert-manager installs two ClusterIssuers:

- letsencrypt-staging for safe certificate-flow testing;
- letsencrypt-prod for browser-trusted production certificates.

Production Ingress resources request certificates through the
cert-manager.io/cluster-issuer annotation. Traefik terminates TLS using the
Secret created by cert-manager.

The production hostname resolves publicly to the Proxmox host. Inside the
production cluster, CoreDNS rewrites that name to the internal Traefik Service
so cert-manager's own HTTP-01 self-check does not depend on hairpin NAT.

## Infrastructure limitations

- Terraform uses local state.
- There is one Proxmox host.
- The cloud-init template is built by a script rather than Packer.
- VM storage and Kubernetes local-path storage are node-local.
- The production control plane is a single k3s server.
- Firewall, certificate, monitoring, and runner setup still require explicit
  operator commands and runtime secrets.
