# Environment strategy

The environments have the same application but different purposes and
different exposure levels. Development optimizes for a fast feedback loop.
Staging validates the Kubernetes deployment. Production is the public demo
environment.

## Environment matrix

| Environment | Branch | Runtime | Namespace | Release | Hostname | Replicas | TLS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Development | Any working branch | Docker Compose | Not applicable | Not applicable | fastapi.localhost | Not applicable | Local HTTP |
| Staging | main | Single-node k3s | staging | staging | staging.k3s.local | 1 | Disabled |
| Production | production | Two-node k3s | production | prod | project.femidevops.abrdns.com | 2 | cert-manager and Traefik |

Staging is not exposed to the Internet. It is reached through an SSH path and
an internal hostname. Production is reached through public DNS, the Proxmox
host's NAT rules, and Traefik.

## Why the environments are separate

The staging and production clusters use different VMs, namespaces, agent
installations, credentials, and deployment releases. A staging deployment
therefore does not modify production resources.

The application image is the same across environments. The orchestration
configuration changes through Helm values. This keeps the application artifact
consistent while allowing staging to remain private and smaller.

## Configuration flow

### Development

The local .env file provides PostgreSQL and Traefik values. Docker Compose
constructs DATABASE_URL for the web container and passes the PostgreSQL
variables to the database container.

### Kubernetes

GitLab CI creates app-secrets in the target namespace. The Helm chart reads
the three PostgreSQL values from that Secret and constructs DATABASE_URL
inside the application Pod.

The chart does not store credentials in values files. Helm stores release
values in the cluster, so passing passwords through Helm would leave them in
release history.

### Infrastructure

Terraform creates the VMs and injects the initial user, SSH key, static private
address, gateway, DNS resolver, and VM sizing through cloud-init. Ansible then
installs the operating-system packages, k3s, GitLab components, certificates,
firewall, and monitoring.

## Environment-specific behavior

| Feature | Development | Staging | Production |
| --- | --- | --- | --- |
| Application image | Local build | GitLab registry image | GitLab registry image |
| Database | Compose volume | StatefulSet and local-path PVC | StatefulSet and local-path PVC |
| Application replicas | One Compose service | One | Two |
| Off-site backup | Not configured | Disabled | Enabled in production values |
| Grafana | Not configured | Internal port-forward | Internal port-forward |
| Public HTTPS | No | No | Yes |
| Deployment | Manual Compose command | Push to main | Manual job on production branch |

## Promotion

Changes are merged into main after the merge-request checks pass. A successful
main pipeline deploys staging. Production is promoted by merging main into the
production branch. The production pipeline then waits for the manual
deployment job.

## Important limitations

- Staging has no public DNS record and no public certificate.
- Production's public NAT path terminates at one Proxmox host and one
  production control-plane address.
- The Kubernetes local-path storage class stores data on a node-local
  directory.
- Environment values describe desired configuration; deployment evidence is
  recorded separately in verification.md.
