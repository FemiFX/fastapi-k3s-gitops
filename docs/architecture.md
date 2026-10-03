# Architecture

## Purpose

This project uses a small FastAPI service to demonstrate a complete delivery
platform. The application is intentionally simple. The architecture work is
in the layers around it: containers, environments, networking, Kubernetes,
CI/CD, security, persistence, monitoring, and recovery.

## Current architecture

Development runs locally with Docker Compose. Staging and production run on
separate k3s clusters hosted on Proxmox virtual machines. GitLab CI builds and
scans the image, then writes its tag into `gitops/`; Argo CD, running inside
each cluster, reconciles the cluster to match. The GitLab Agent remains for
the two things Argo CD does not own: creating Secrets and confirming a release
actually rolled out.

The diagrams for every layer are in [diagrams.md](diagrams.md).

The current platform contains:

- FastAPI and Ormar;
- PostgreSQL 15;
- Traefik;
- Docker Compose;
- k3s;
- a Helm application chart;
- Terraform for Proxmox VMs;
- Ansible for VM and cluster configuration;
- GitLab Runner and GitLab Agent;
- cert-manager for Kubernetes certificates;
- kube-prometheus-stack for metrics and dashboards;
- Alertmanager for alert routing;
- a nightly PostgreSQL backup;
- production off-site backup support through restic and Cloudflare R2.

Loki collects container logs on staging, with Grafana Alloy as the
collector and a Loki datasource in Grafana, so metrics and logs sit on one
timeline. Production is not yet collected: staging carries the risk first,
because log collection runs a privileged DaemonSet on every node it is
installed on.

## Decisions

| Area | Decision | Reason |
| --- | --- | --- |
| SCM and CI/CD | GitLab.com and GitLab CI | The repository and deployment workflow are hosted there |
| Host | Self-hosted Proxmox VE | The project can demonstrate VM, network, and cluster management directly |
| Runtime | k3s on Proxmox VMs | k3s provides Kubernetes behavior with a smaller footprint |
| Environments | Local Compose, staging k3s, production k3s | The environments have different purposes and failure boundaries |
| VM provisioning | Terraform with the Proxmox provider | VM existence and sizing are declared as code |
| VM and cluster setup | Ansible and cloud-init | Operating-system and cluster configuration can be repeated |
| Application deployment | Helm | Helm values make the two application environments explicit and Helm records releases |
| Database | PostgreSQL StatefulSet and PersistentVolume | The application needs persistent state inside the cluster |
| Monitoring | kube-prometheus-stack | It provides Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics in one stack |
| Certificate management | cert-manager with an HTTP-01 ClusterIssuer | Certificate issuance and renewal are separate from Traefik request routing |

## Environment topology

| Environment | Runtime | Host or cluster | Namespace | Helm release | Exposure |
| --- | --- | --- | --- | --- | --- |
| Development | Docker Compose | Local workstation | Not applicable | Not applicable | Local ports 8008 and 8081 |
| Staging | Single-node k3s | VM 10.10.10.20 | staging | staging | Internal; reached through an SSH path |
| Production | Two-node k3s | VMs 10.10.10.30 and 10.10.10.31 | production | prod | Public HTTPS through the Proxmox host |

The Proxmox host has one public address. The VMs use the private
10.10.10.0/24 network on vmbr1. The host performs NAT for outbound traffic and
forwards public ports 80 and 443 to the production server at 10.10.10.30.

This means production has two application and Traefik replicas, but it does
not have complete host-level high availability. The Proxmox host, production
control plane, PostgreSQL instance, and public NAT path remain important
failure boundaries.

## Request flow

### Development

~~~text
Browser
  -> localhost:8008
  -> Traefik in Docker Compose
  -> web Service
  -> FastAPI
  -> PostgreSQL
~~~

### Staging

~~~text
Browser or smoke-test Pod
  -> staging hostname and internal path
  -> k3s Traefik
  -> staging Ingress
  -> staging application Service
  -> FastAPI Pods
  -> PostgreSQL StatefulSet
~~~

### Production

~~~text
Internet
  -> DNS for project.femidevops.abrdns.com
  -> Proxmox public address
  -> NAT forwarding to 10.10.10.30
  -> k3s Traefik
  -> TLS certificate from cert-manager
  -> production Ingress
  -> application Service
  -> FastAPI Pods
  -> PostgreSQL StatefulSet
~~~

HTTP is redirected to HTTPS in the production Ingress. Port 80 must remain
reachable because the HTTP-01 certificate challenge uses it.

## Deployment flow

~~~text
Feature branch
  -> merge request
  -> quality, tests, build, configuration scan, secret scan
  -> merge to main
  -> image build and scan
  -> automatic staging deployment
  -> smoke test
  -> merge main into production
  -> production pipeline
  -> manual production deployment
  -> smoke test
~~~

Images are tagged with the commit short SHA. The deployment passes that tag to
Helm, so an environment can be traced back to the source commit.

## Application layer

The FastAPI application exposes:

- GET / for the user list;
- GET /health for dependency-free liveness;
- GET /ready for database and schema readiness;
- GET /metrics for Prometheus metrics.

The application uses a lifespan context. It opens the async database connection,
creates missing tables, creates the seed user, serves requests, and closes the
connection on shutdown.

## Kubernetes layer

The Helm chart creates the following application resources:

- Deployment for the FastAPI Pods;
- ClusterIP Service for internal routing;
- Ingress for hostname routing;
- Traefik Middleware for HTTPS redirection;
- StatefulSet for PostgreSQL;
- headless PostgreSQL Service;
- database PersistentVolumeClaim;
- backup PersistentVolumeClaim;
- backup CronJob;
- PodDisruptionBudget when more than one application replica is configured.

Production uses two application replicas. The Deployment uses a rolling update
with zero unavailable replicas and one surge replica. Topology spreading asks
the scheduler to place replicas on different nodes. The PodDisruptionBudget
protects one replica during voluntary disruption such as node draining.

The database remains one StatefulSet replica. The data tier is recoverable
through backups, but it is not a highly available PostgreSQL cluster.

The chart's shared instance labels currently appear on both the application and
database Pods. The database adds a component label, but the Deployment selector
does not use that label. Ownership remains correct because the StatefulSet and
Deployment have different controllers, but broad label queries can return both
workloads. When inspecting logs, identify the exact application Pod rather than
assuming that a Deployment-level query selected the web container.

## Security and access boundaries

The application container runs as UID 10001, with a read-only root filesystem,
no privilege escalation, a default seccomp profile, and all Linux capabilities
dropped. PostgreSQL is not exposed outside the cluster.

The GitLab Agent is granted a namespace-scoped Role for deployment resources.
It has a separate, read-only discovery ClusterRole and a small Role allowing
the agent to manage itself. It cannot manage unrelated namespaces.

The monitoring services are ClusterIP services. Grafana is accessed through
kubectl port-forward over SSH and is not exposed to the public Internet.

## Remaining limitations

- PostgreSQL is a single replica.
- The k3s control plane is not highly available.
- The Proxmox host is a single hypervisor and public NAT point.
- The local-path storage class is node-local.
- Restores are manual.
- Off-site retention pruning is manual.
- Centralized logging covers staging only; production still relies on kubectl.
- The public metrics endpoint still needs an explicit exposure decision.
