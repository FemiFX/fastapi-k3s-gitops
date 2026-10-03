# Requirements

## Purpose and context

This project uses a deliberately small FastAPI users API to demonstrate a
complete DevOps delivery model. The important outcome is not a large business
feature set. It is a service that can be developed locally, tested
automatically, deployed reproducibly, operated securely, observed, and
recovered.

The target platform is a self-hosted Proxmox VE environment. GitLab.com
provides source control and CI/CD. Staging and production run on k3s clusters,
with Helm as the application packaging layer.

## Stakeholders

| Stakeholder | Need |
| --- | --- |
| Developer | fast local feedback, tests, and predictable configuration |
| Operations | repeatable deployment, health signals, backups, and recovery procedures |
| Security reviewer | protected secrets, HTTPS, least privilege, and scan results |
| Assessor | clear evidence of application, infrastructure, automation, and operations |

## Functional requirements

| ID | Requirement | Current implementation and evidence | Status |
| --- | --- | --- | --- |
| FR-A1 | Expose an HTTP API through FastAPI. | app/main.py creates the application and routes. | Complete |
| FR-A2 | Read persistent data from PostgreSQL. | Ormar User model and async PostgreSQL engine; / reads users. | Complete |
| FR-A3 | Make application and database state distinguishable. | /health is DB-independent; /ready checks the users table and returns 503 when it cannot serve requests. | Complete |
| FR-D1 | Run the stack locally with a documented command. | Docker Compose starts FastAPI, PostgreSQL, and Traefik. | Complete |
| FR-D2 | Run automated checks locally and in CI. | pytest, Ruff, and Bandit are defined in the repository and pipeline. | Complete |
| FR-D3 | Use a defined contribution and promotion workflow. | Feature branches merge into main; production is promoted separately. | Complete |
| FR-O1 | Deploy staging and production through CI/CD. | GitLab CI deploys staging automatically and production through a manual job. | Complete |
| FR-O2 | Expose production through HTTPS. | Traefik Ingress, redirect Middleware, and cert-manager certificate resources. | Complete |
| FR-O3 | Provide metrics, dashboards, and alerts. | Prometheus, Grafana, ServiceMonitor, PrometheusRule, and optional Mattermost/Healthchecks routing. | Partial: live verification is required |
| FR-O4 | Back up and restore PostgreSQL. | Implemented local dump flow, production restic/R2 path, and documented restore Jobs. | Partial: live drill evidence is required |
| FR-S1 | Keep secrets out of source control and Helm history. | CI creates app-secrets from protected variables; secrets are referenced by name. | Complete |
| FR-S2 | Protect operational interfaces. | Traefik dashboard is routed through authentication and should not be publicly exposed without it. | Partial: verify the live route |
| FR-S3 | Scan code, dependencies, configuration, secrets, and images. | Ruff/Bandit and Trivy jobs run before deployment; scheduled deployed-image scan is available. | Complete |

The application currently exposes read behavior rather than a complete CRUD
interface. There is no user-creation endpoint: the initial test user is seeded
during application startup when the table is empty. This is sufficient for the
platform demonstration and should not be described as a full user-management
product.

## Non-functional requirements

| ID | Requirement | Implementation | Status |
| --- | --- | --- | --- |
| NFR-1 | Reproducibility from version-controlled automation. | Terraform, Ansible, Helm, Compose, and GitLab CI are stored in the repository. | Complete with normal environment prerequisites |
| NFR-2 | HTTPS-only production traffic. | Traefik redirects HTTP to HTTPS and obtains certificates through cert-manager. | Partial: certificate renewal and redirect need periodic live checks |
| NFR-3 | Environment isolation. | Local Compose, staging VM/cluster, and production VMs/cluster use separate namespaces, values, credentials, and hostnames. | Complete |
| NFR-4 | Database data survives workload restarts. | PostgreSQL StatefulSet uses a persistent volume claim. | Complete: deletion and node-loss behavior remain separate concerns |
| NFR-5 | Recoverability. | Nightly local dumps, production off-site restic/R2 copies, and restore instructions. | Partial: RPO/RTO and recurring drills must be formalized |
| NFR-6 | Diagnosability. | Health endpoints, Prometheus metrics, Grafana dashboards, alert rules, and Loki log aggregation queried through Grafana. | Partial: log collection covers staging only |
| NFR-7 | Automated quality gates. | Quality, test, build, scan, and deployment stages run in GitLab CI. | Complete with the documented merge-request push caveat |
| NFR-8 | Human-operable documentation. | Reference docs, runbook, verification matrix, and demo script cover the delivery path. | Partial: live evidence must be kept current |
| NFR-9 | Production availability during normal releases. | Two app replicas, rolling update settings, topology spread, and a PodDisruptionBudget. | Complete for application Pods; database remains a single StatefulSet |
| NFR-10 | Supply-chain visibility. | Commit-derived image tags, registry storage, Trivy scans, and a deployed-image scheduled scan. | Complete with reviewed exceptions |

## Resolved design decisions

- Platform: self-hosted Proxmox VE.
- Runtime: k3s on Proxmox VMs.
- Source control and CI/CD: GitLab.com and GitLab CI.
- Environments: local development, staging, and production.
- Application packaging: Docker images and a Helm chart.
- Database: self-hosted PostgreSQL in the cluster.
- Monitoring: kube-prometheus-stack with Prometheus and Grafana.
- Production backup: local PostgreSQL dump plus encrypted restic upload to
  Cloudflare R2.
- Deployment strategy: rolling update with two production application replicas.

## Requirements outside the current scope

The following are intentionally not represented as completed requirements:

- managed PostgreSQL failover or multi-primary database replication;
- blue/green or canary application delivery;
- automatic off-site retention pruning;
- centralized log collection on production, and full-text indexing of the kind ELK or OpenSearch provides;
- a complete CRUD API and authentication for application users;
- a formal uptime SLA beyond the demonstration environment.

## Evidence rules

A source file proves that a capability is designed. A successful pipeline proves
that the automated job ran. A live URL, dashboard, alert, backup, or restore
record proves that the deployed capability worked at a particular time. The
current evidence to collect is tracked in [verification.md](verification.md).
