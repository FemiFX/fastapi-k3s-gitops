# Verification matrix

This document records what can be demonstrated from the repository and what
still needs a live verification record. A manifest proves that a behavior is
configured; it does not prove that the behavior has worked in the target
environment.

| Area | Evidence in repository | Verification to record |
| --- | --- | --- |
| Local application | Compose files and app/ | docker compose up and endpoint responses |
| API tests | tests/ | Successful pytest output |
| Formatting and linting | pyproject.toml and CI lint job | Successful Ruff and Black output |
| Image build | Dockerfile.prod and CI build job | Image digest and commit tag |
| Secret scanning | CI scan:secrets job | Green pipeline result |
| Configuration scanning | CI scan:config job | Green pipeline result and reviewed findings |
| Image scanning | CI scan:image job and .trivyignore.yaml | Container scan report and gate result |
| Scheduled image scan | CI scan:deployed job | Scheduled pipeline result |
| Staging deployment | GitOps Application, release and sync jobs | Rollout and smoke-test output |
| Production deployment | Production GitOps Application and manual release job | Approved deployment record and HTTPS response |
| Infrastructure | Terraform and Ansible | terraform plan, Ansible recap, node list |
| TLS | cert-manager role and production Ingress | Ready ClusterIssuer, Certificate, and browser/curl check |
| Monitoring | Monitoring Ansible role and ServiceMonitor | Prometheus target, dashboards, and loaded rules |
| Alert routing | Optional Mattermost and Healthchecks variables | Test alert received and dead-man's switch observed |
| Local backup | Helm backup CronJob | Verified dump and retention listing |
| Off-site backup | Production restic container | Remote snapshot and repository check |
| Restore | Helm README procedure | Staging restore drill with matching row count |
| Availability | Replica spread, rolling strategy, PDB | Pods on separate nodes and successful rollout/drain test |
| Log collection | Loki and Alloy Applications in gitops/ | Loki label query returning namespaces, and a LogQL query in Grafana |
| Environment rebuild | infra:destroy:staging, rebuild-staging.md, scripts/bootstrap.sh | Dated drill record with the defects found |
| Disaster recovery | disaster-recovery.md | RPO/RTO stated, and which drills have actually been run |

## Evidence rules

Evidence should include the date, environment, commit SHA, command or pipeline
job, and result. Screenshots are useful for the defense, but command output or
pipeline artifacts are better when the behavior needs to be reproduced.

The production backup and alert-routing changes currently need a final live
verification after they are committed. Until then, they should be described as
configured in the working tree, not as a completed operational drill.

The same distinction applies to the full host-loss recovery path in
[disaster-recovery.md](disaster-recovery.md). Every piece of it has been
exercised separately, but the path as a whole has never been executed, and it
is described that way deliberately.
