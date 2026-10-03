# Configuration reference

Configuration is supplied through the environment rather than hardcoded in
the application. The same plain PostgreSQL URL format is used by Compose, CI,
and Helm; the application normalizes it to the async driver internally.

## Dependency reproducibility

The main framework dependencies and development tools are pinned where the
project makes a deliberate version choice. A few transitive or compatibility
constrained packages use bounded ranges, such as pydantic-settings, asyncpg,
httpx, and uvicorn. This is sufficient for the training workflow, but a
lockfile would be needed for byte-for-byte dependency reproducibility across
machines and over time.

## Application and Compose variables

| Variable | Required | Used by | Description |
| --- | --- | --- | --- |
| DATABASE_URL | Yes outside Compose | FastAPI | PostgreSQL connection URL |
| POSTGRES_USER | Yes in production | PostgreSQL and Compose | Database login name |
| POSTGRES_PASSWORD | Yes in production | PostgreSQL and Compose | Database password |
| POSTGRES_DB | Yes in production | PostgreSQL and Compose | Database name |
| APP_DOMAIN | Yes in production | Traefik | Hostname routed to FastAPI |
| TRAEFIK_DASHBOARD_DOMAIN | Yes in production | Traefik | Hostname for the protected dashboard |
| TRAEFIK_DASHBOARD_AUTH | Yes in production | Traefik | htpasswd-formatted basic-auth value |
| ACME_EMAIL | Yes in production | Traefik | Let's Encrypt contact address |
| ACME_CA_SERVER | No | Traefik | ACME endpoint; defaults to Let's Encrypt production |
| DB_HOST | No | prestart.sh | PostgreSQL hostname; defaults to db |
| DB_PORT | No | prestart.sh | PostgreSQL port; defaults to 5432 |

.env.example is the safe list of local variables. Real .env files are
ignored by Git.

## Helm values

The chart combines values.yaml with one environment file:

- values-staging.yaml sets the staging hostname, one application replica,
  and a 5 GiB database volume;
- values-production.yaml sets the public hostname, HTTPS, two application
  replicas, a 10 GiB database volume, and production off-site backup support.

The pipeline overrides image.repository and image.tag with the GitLab
Container Registry path and the commit short SHA. The chart refers to the
Kubernetes Secret app-secrets for database credentials. Helm values do not
contain those credentials because Helm stores release values in the cluster.

Important chart settings include:

| Setting | Default or production behavior |
| --- | --- |
| containerPort | 8000; the non-root application cannot bind to port 80 |
| securityContext | Non-root UID 10001, read-only root filesystem, no privilege escalation, dropped capabilities |
| probes | /health for liveness/startup and /ready for readiness |
| replicaCount | 1 by default, 2 in production |
| topologySpread | Spreads multiple application replicas across nodes |
| podDisruptionBudget | Protects one production replica during voluntary disruption |
| backup.schedule | 15 2 * * *, or 02:15 UTC |
| backup.retentionDays | 14 days |
| backup.offsite.enabled | Disabled by default, enabled in production values |

## CI/CD variables

The deploy jobs require:

- POSTGRES_USER;
- POSTGRES_PASSWORD;
- POSTGRES_DB.

Production off-site backup support additionally uses:

- RESTIC_REPOSITORY;
- RESTIC_PASSWORD;
- R2_ACCESS_KEY_ID;
- R2_SECRET_ACCESS_KEY.

The pipeline creates app-secrets and, when the repository variable is set,
backup-offsite inside the target namespace. These values are supplied at
deploy time and are not passed to Helm with --set.

GitLab also supplies the registry credentials and the agent kubeconfig used by
the deployment job.

## Terraform variables

Terraform reads the Proxmox endpoint, API token, SSH key, network values, VM
template ID, and VM sizing from variables. The API token and state file must
remain outside Git. A local terraform.tfvars file is ignored, and CI can use
TF_VAR_* environment variables.

## Ansible runtime variables

The following values are intentionally passed at runtime:

- gitlab_registration_token for the self-hosted runner;
- gitlab_agent_token for each Kubernetes cluster agent;
- acme_email for cert-manager;
- grafana_admin_password for monitoring;
- mattermost_webhook_url and optional mattermost_channel for alert delivery;
- healthchecks_ping_url for the monitoring dead-man's switch;
- alert_send_test=true when deliberately testing alert delivery.

Sensitive values should be passed through a protected secret store or a local
environment variable. They should not be placed in inventory, committed YAML,
or shell history where that can be avoided.
