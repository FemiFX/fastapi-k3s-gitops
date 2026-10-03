# Demo Script

## Purpose

This is a repeatable outline for the final project demonstration. The
application is intentionally small; the demonstration should therefore spend
most of its time showing how the application is packaged, delivered, secured,
observed, and recovered.

The sequence below fits a 20-minute presentation and leaves time for
questions. Live evidence should be collected before the presentation and
rehearsed from the same commands.

## Preflight

Before the demo:

- confirm that the intended commit is present on main and, if needed,
  production;
- open the GitLab pipeline, staging URL, production URL, Grafana, and the
  repository;
- verify that the production certificate is valid;
- confirm that staging and production kubeconfigs work;
- run a recent backup and record its Job name, timestamp, and verification
  output;
- prepare screenshots or terminal output for steps that depend on an
  unreliable network connection.

Do not expose CI variables, kubeconfig contents, database passwords, or restic
repository passwords during the presentation.

## 1. State the problem and scope

Explain that the repository uses a small FastAPI users API to demonstrate a
complete delivery path:

1. develop and test locally with Docker Compose;
2. build and scan an immutable container image in GitLab CI;
3. deploy to staging and production on k3s with Helm;
4. expose production through Traefik and HTTPS;
5. collect metrics and alerts with Prometheus and Grafana;
6. persist and recover PostgreSQL data.

The point is the platform and operating model, not business-domain
complexity.

## 2. Show the architecture

Open [architecture.md](architecture.md) and explain the three environments:

- local Compose for fast feedback;
- a single-node staging k3s cluster on the staging VM;
- a two-node production k3s cluster on separate VMs.

Trace one production request:

Internet -> Traefik -> Ingress -> FastAPI Service -> FastAPI Pod ->
PostgreSQL Service -> PostgreSQL StatefulSet

Then point out that Prometheus reaches the application's /metrics endpoint
through a ServiceMonitor, while database data is stored on a persistent volume.

## 3. Run the application locally

From the repository root:

~~~sh
docker compose up --build
curl http://fastapi.localhost:8008/health
curl http://fastapi.localhost:8008/ready
curl http://fastapi.localhost:8008/
~~~

Explain the responses:

- /health proves that the process can answer without depending on the
  database;
- /ready proves that the database connection and users table are available;
- / reads the users from PostgreSQL.

Show the test suite and the relevant files in app/ and tests/. The seed user
is created during application startup when the table is empty.

## 4. Show the delivery pipeline

Open .gitlab-ci.yml and a completed pipeline. Walk through the stages:

1. quality checks with Ruff and Bandit;
2. pytest execution;
3. Docker image build and registry publication;
4. Trivy configuration, secret, dependency, and image scans;
5. Helm deployment to staging;
6. production deployment from the production branch after manual approval.

Explain that the image tag is derived from the commit SHA. This makes the
deployed artifact identifiable and allows a release to be tied back to source
code.

Point out the two scan policies: HIGH findings are reported and can block
depending on the scan, while fixable HIGH and CRITICAL image findings are
gated. .trivyignore.yaml contains reviewed exceptions rather than silently
discarding all findings.

## 5. Show staging deployment

Open the staging pipeline job and its deployment output. Verify the workload:

~~~sh
kubectl --kubeconfig /path/to/kubeconfig-staging.yaml \
  -n staging get pods,svc,ingress
kubectl --kubeconfig /path/to/kubeconfig-staging.yaml \
  -n staging rollout status deployment/staging-fastapi-app
~~~

Run the internal smoke checks or show the pipeline output proving that the
service returned the expected status. Explain that staging uses one
application replica and does not enable off-site backup upload.

## 6. Show the production HTTPS path

Open the production hostname and show:

- the browser's valid certificate;
- the FastAPI response;
- HTTP redirecting to HTTPS, if the endpoint is tested directly;
- the Traefik Ingress and Middleware definitions in the Helm chart.

Production uses two FastAPI replicas, a PodDisruptionBudget, topology spread,
and a rolling update policy. These settings are intended to keep one replica
available during a normal application rollout.

The Traefik dashboard is an operational interface, not an application
endpoint. Show that it is protected and do not demonstrate it by publishing
credentials.

## 7. Demonstrate database persistence

Record the current user count, restart the application or database workload
as appropriate, and query again:

~~~sh
kubectl -n production exec prod-fastapi-app-db-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from users;"'
kubectl -n production get pvc
~~~

Explain that PostgreSQL runs in a StatefulSet and its data directory is
mounted from a persistent volume claim. A Pod restart is not the same as
deleting the volume; the persistence claim is what preserves the data.

## 8. Show monitoring and alerting

Open Grafana through the documented SSH port-forward and show the application
and cluster dashboards. Then show the Prometheus targets and alert rules.

The application exposes request counters, latency histograms, and in-progress
request counts. The ServiceMonitor discovers the application Service in the
staging or production namespace. PrometheusRule covers application readiness,
target availability, PostgreSQL health, and backup freshness.

If Mattermost or Healthchecks.io is configured, show the receiver or
dead-man's-switch result without displaying the webhook or token. Otherwise,
explain that the optional integrations are disabled while Prometheus and
Grafana remain available.

## 9. Show backup and restore evidence

Show the latest backup Job and its successful verification:

~~~sh
kubectl -n production get cronjob,jobs
kubectl -n production logs job/<backup-job>
~~~

Explain the sequence:

1. pg_dump creates a compressed dump;
2. the dump is checked before it is renamed into place;
3. restic encrypts and deduplicates the backup;
4. production uploads it to Cloudflare R2;
5. the cluster credential cannot delete remote backups.

Use staging for a live restore drill. Never deliberately drop a production
table for a presentation. The restore evidence should show the original row
count, the restore Job output, and the post-restore /ready and application
responses.

## 10. Show infrastructure and security

Open the Terraform and Ansible directories and explain the ownership boundary:

- Terraform creates the Proxmox VMs and network-facing settings;
- Ansible installs common host configuration, k3s, GitLab Runner, and GitLab
  Agent;
- Helm installs the application and PostgreSQL resources.

Highlight the production controls:

- private VM addressing and host firewall rules;
- HTTPS at the Traefik boundary;
- CI-created Kubernetes Secrets;
- non-root application container;
- read-only root filesystem and dropped Linux capabilities;
- restricted Agent permissions;
- Trivy scanning before deployment.

## 11. State limitations clearly

Close by naming the known boundaries:

- PostgreSQL is self-hosted and therefore does not provide managed database
  failover;
- the database and local backup volume are node-local;
- off-site retention is manual because the cluster credential has no delete
  permission;
- log collection through Loki covers staging only; production logs are still
  read with kubectl;
- the deployment is rolling rather than blue/green or canary;
- live backup, restore, and alert routing still need periodic verification.

These are deliberate scope boundaries and form the next improvement backlog.

## Evidence checklist

Prepare one concise piece of evidence for each claim:

- local startup and API response;
- passing tests and quality jobs;
- image tag and registry entry;
- Trivy scan result;
- staging rollout;
- production HTTPS certificate;
- two production replicas and PVC;
- Grafana dashboard and Prometheus targets;
- verified local and off-site backup;
- restore result;
- Terraform/Ansible/Helm source;
- known limitations and next steps.
