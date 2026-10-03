# Project Goals and Delivery Plan

## Project context

fastapi-docker-traefik is a training project built around a small FastAPI
users API. The application is intentionally simple so that the delivery system
can be examined end to end: local development, automated quality checks,
container supply chain, infrastructure provisioning, Kubernetes deployment,
HTTPS, persistence, monitoring, and recovery.

The target runtime is self-hosted Proxmox VE. Terraform provisions the virtual
machines, Ansible configures them, k3s provides the Kubernetes runtime, and
Helm packages the application and database resources. GitLab.com hosts the
repository and runs the CI/CD pipeline.

## Desired outcome

The finished project should allow a new operator to:

1. start the application locally from documented instructions;
2. understand the request path and environment boundaries;
3. validate changes through tests, linting, security checks, and image scans;
4. deploy an identifiable image to staging and production;
5. serve production over HTTPS through Traefik;
6. see application and cluster signals in Prometheus and Grafana;
7. back up PostgreSQL and restore it using a repeatable procedure;
8. identify the remaining risks instead of mistaking a demonstration setup for
   a highly available managed platform.

## Current delivery status

| Area | Current state | Status |
| --- | --- | --- |
| FastAPI application | Async PostgreSQL access, startup table creation/seed, health and readiness endpoints, Prometheus metrics | Complete |
| Local development | Compose stack with FastAPI, PostgreSQL, and Traefik | Complete |
| Tests and quality | pytest, Ruff, and Bandit jobs | Complete |
| Container build | Commit-addressable production image, non-root runtime, hardened container settings | Complete |
| CI/CD | GitLab pipeline for quality, tests, build, scans, and GitOps release; Argo CD reconciles both clusters | Complete |
| Infrastructure | Terraform Proxmox VM definitions and Ansible host/k3s/runner/agent configuration | Complete with environment prerequisites |
| Kubernetes packaging | Helm chart for app, database, Ingress, middleware, backup, PDB, and monitoring integration | Complete |
| Environment separation | Local Compose, staging k3s, production two-node k3s | Complete |
| HTTPS | Traefik and cert-manager resources with HTTP-to-HTTPS redirect | Implemented; live renewal evidence required |
| Persistence and backup | PostgreSQL PVC, nightly dump, production restic/R2 off-site copy, restore procedures, stated RPO/RTO | Implemented; staging restore drilled, off-site restore not yet |
| Observability | kube-prometheus-stack, ServiceMonitor, PrometheusRule, Grafana, Loki and Alloy for logs, Mattermost routing | Implemented; staging alert delivery verified, production delivery still to record |
| Documentation | Reference docs, runbook, demo script, and verification matrix | In progress: keep evidence current |

## Delivery phases

### Phase 0: framing and scope

The scope, stakeholders, target environment, and demonstration objective are
defined. The project is intentionally limited to a small API and a
self-managed platform so the operational decisions remain visible.

### Phase 1: specifications and repository structure

Requirements, architecture, environment strategy, Git workflow, and the
documentation index are now part of the repository. The architecture records
the boundaries between Terraform, Ansible, Helm, GitLab CI, and the
application.

### Phase 2: application hardening and tests

The application has an async database lifecycle, explicit liveness and
readiness behavior, a schema-aware readiness query, startup seeding, and
Prometheus request metrics. The container runs as UID 10001 with a read-only
root filesystem and dropped capabilities. Tests cover the main endpoint and
database behavior.

### Phase 3: CI/CD

The GitLab pipeline runs quality and test stages, builds and pushes an image,
scans configuration/secrets/dependencies/images, deploys staging, performs
smoke checks, and exposes production as a manual deployment from the
production branch. A scheduled job can scan the deployed production image.

One item remains for explicit verification: the merge-request rule currently
describes a no-push behavior while the build script still contains an
unconditional registry push. That behavior should be reconciled before the
pipeline is presented as fully deterministic.

### Phase 4: infrastructure automation

Terraform creates the four Proxmox VMs. Ansible applies common host settings,
the k3s server and agent configuration, the GitLab Runner, and the GitLab
Agent. Host firewall rules, private addressing, and the staging/production
topology are documented in infrastructure.md.

### Phase 5: data management

PostgreSQL runs as a StatefulSet with persistent storage. The backup CronJob
creates and verifies compressed dumps. Production uploads them with restic to
Cloudflare R2 using credentials that cannot delete remote objects. Restore
procedures cover both the local PVC and an off-site repository.

### Phase 6: security hardening

Production traffic is terminated at Traefik with HTTPS. Secrets are supplied
by GitLab CI and referenced by Kubernetes resources. The application image is
non-root and hardened, Kubernetes access is namespace-scoped where possible,
and Trivy checks the repository and image before deployment.

### Phase 7: observability

The monitoring role installs kube-prometheus-stack. The chart exposes
application metrics through a ServiceMonitor, and PrometheusRule defines
availability, database, and backup alerts. Grafana is reached through an SSH
port-forward. Mattermost and Healthchecks.io integrations are optional and
must be verified in the environment where they are enabled.

Centralized log collection is implemented on both environments: Loki stores
logs, Grafana Alloy collects them from every node, and Grafana queries both
metrics and logs on one timeline.

### Phase 8: final demonstration and handover

The final demo should connect a code change to a running, monitored, and
recoverable service. The operator should be able to explain the normal release
path and show how a failed readiness check, failed backup, or bad Helm release
would be investigated.

## Remaining backlog

Items 1, 5 and 6 of the original backlog are done; the rest are restated below
with their current status.

1. ~~Reconcile the merge-request image-push behavior.~~ Done: the `build` job
   reads a `PUSH` variable that the merge-request rule sets to `"false"`.
2. **Record the drills.** Staging backup and restore have both been run, as
   has a full staging rebuild. The **production off-site restore from R2 has
   not**, and neither has full host loss.
3. **Verify the live HTTPS route and renewal.** The route works; a renewal has
   not been observed, because certificates last 90 days and the environment is
   younger than that in its current shape. The Traefik dashboard item is
   withdrawn — the dashboard is not exposed at all, so there is nothing to
   authenticate.
4. **Alert delivery.** Verified on staging by a real `BackupJobFailed` arriving
   in Mattermost. **Production Mattermost delivery and the Healthchecks.io
   dead-man's switch still need a recorded test.**
5. ~~Define RPO and RTO.~~ Done: [disaster-recovery.md](disaster-recovery.md).
6. ~~Decide whether centralized logs are required.~~ Done and built, both
   environments.
7. **Keep verification.md updated** after every live change.

## Success criteria

The project is ready for handover when the local path, CI/CD path, remote
deployment, HTTPS access, persistent data, monitoring, and restore procedure
can each be demonstrated or backed by dated evidence. The documentation
should distinguish clearly between implemented source configuration and
capabilities that have been verified in a live environment.

## Documentation map

- [README.md](../README.md): first entry point and quickstart.
- [application.md](application.md): application behavior and endpoints.
- [architecture.md](architecture.md): system boundaries and request flows.
- [configuration.md](configuration.md): variables and environment inputs.
- [ci-cd.md](ci-cd.md): pipeline stages and release flow.
- [infrastructure.md](infrastructure.md): Terraform and Ansible.
- [security.md](security.md): security controls and limitations.
- [data-management.md](data-management.md): persistence, backup, and restore.
- [observability.md](observability.md): metrics, dashboards, and alerts.
- [runbook.md](runbook.md): operating and troubleshooting procedures.
- [demo-script.md](demo-script.md): presentation sequence and evidence.
- [verification.md](verification.md): source and live verification matrix.
