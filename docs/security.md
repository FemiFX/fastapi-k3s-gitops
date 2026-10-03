# Security

## Purpose

Security in this project is layered. The controls protect traffic, credentials,
the container, the Kubernetes API, the host network, and the operational
interfaces.

## Traffic and ingress

Production traffic enters through Traefik. Port 80 redirects to HTTPS, while
port 443 serves the certificate issued by cert-manager.

The certificate uses an HTTP-01 challenge. Port 80 must remain reachable while
the certificate is being issued or renewed. Staging does not request a public
certificate because it is intentionally not Internet-facing.

The Traefik dashboard is not exposed. k3s installs Traefik with the dashboard
disabled and it has not been enabled, so there is no route to it and no
credentials to manage. Traefik's own configuration is inspected with
`kubectl` on the node rather than through a web interface.

The same reasoning applies to Grafana and the Argo CD UI: both are ClusterIP
only and reached with `kubectl port-forward` over the SSH jump host. An admin
console on a public address is a standing liability that buys nothing here.

## Secrets

Real passwords, tokens, private keys, certificates, Terraform state, local
environment files, and generated kubeconfigs are excluded from Git.

Kubernetes database credentials are created by GitLab CI in the target
namespace. Helm refers to the Secret by name and does not receive the values
through Helm parameters.

The production backup Secret contains the restic repository, encryption
password, and R2 credentials. The R2 credentials used by the cluster do not
have delete permission. Grafana and alert-delivery credentials are passed to
Ansible at runtime.

## Host and network controls

The VMs use a private 10.10.10.0/24 network. The Proxmox host is the only
public NAT point. The host firewall defaults to deny and permits only the
required SSH, Proxmox web, HTTP, HTTPS, and ICMP traffic.

The common Ansible role disables password-based SSH and direct root SSH access
on the VMs. Access uses the configured SSH key and ProxyJump through the
Proxmox host.

## Container controls

The production image:

- uses the official Python slim base;
- removes pip, setuptools, and wheel after installation;
- runs as UID 10001;
- listens on high port 8000;
- runs with a read-only root filesystem in Kubernetes;
- disables privilege escalation;
- drops all Linux capabilities;
- uses the RuntimeDefault seccomp profile;
- writes only to an ephemeral /tmp mount.

The Service still exposes port 80 inside the cluster and forwards to the
container's named HTTP port 8000. This allows the application to run without
the privilege normally needed for port 80.

## Kubernetes access

The GitLab Agent provides CI access through an outbound connection to GitLab.
The deployment process does not store an administrator kubeconfig in GitLab.

The repository's agent configuration only allows this GitLab project to use the
staging or production agent. The actual Kubernetes permissions come from the
namespace-scoped Role and discovery permissions installed by Ansible. These are
two separate controls: project access decides who may open the connection, and
RBAC decides what that connection may do.

The agent has:

- a namespace-scoped Role for application deployment;
- a read-only discovery ClusterRole;
- a separate Role for its own leases and service resources.

The agent cannot manage unrelated namespaces. Every new Kubernetes resource
kind needs a corresponding RBAC rule before Helm can deploy it.

## Supply-chain controls

GitLab CI runs:

- Ruff and Black;
- Trivy configuration scanning for Helm and Terraform;
- Trivy secret scanning;
- Trivy image scanning;
- scheduled scans of the deployed image.

The image scan blocks fixable HIGH and CRITICAL findings. Unfixed findings are
reported but ignored by the gate because no remediation is available. Any
accepted fixable finding must have a reason and an expiry date in
.trivyignore.yaml.

## Remaining risks

- The application metrics endpoint is routed through the public application
  Ingress and may expose operational information.
- Terraform skips Proxmox certificate verification by default because the
  Proxmox certificate is self-signed.
- Ansible's configuration uses a permissive host-key setting; the SSH config
  still uses accept-new behavior for first contact.
- PostgreSQL is self-hosted and single-replica.
- The Proxmox host and production control-plane address remain availability
  dependencies.
- Alerting is only useful when a notification channel and, ideally, a
  dead-man's-switch check are configured.
