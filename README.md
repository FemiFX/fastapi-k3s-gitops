# FastAPI, Docker, Traefik, and Kubernetes

This repository contains a small FastAPI application and the platform around
it. The application reads users from PostgreSQL. Docker Compose provides the
local development stack. Staging and production run on k3s clusters hosted on
Proxmox virtual machines. Traefik provides ingress. GitLab CI tests, builds, and scans the image, then
updates the release tag in Git. Argo CD pulls that change and reconciles the
staging and production clusters.

The application is deliberately small. The useful engineering lessons are in
the way it is packaged, tested, secured, deployed, monitored, and recovered.

## Quick start: local development

Docker and Docker Compose are required.

Copy the example environment file and start the stack:

~~~sh
cp .env.example .env
docker compose up -d --build
~~~

The development stack contains:

- web: the FastAPI application;
- db: PostgreSQL 15;
- traefik: the local reverse proxy.

The application is available at:

- http://fastapi.localhost:8008/ — the user list;
- http://fastapi.localhost:8008/health — dependency-free liveness;
- http://fastapi.localhost:8008/ready — database and schema readiness;
- http://fastapi.localhost:8008/metrics — Prometheus metrics;
- http://fastapi.localhost:8081/ — the local Traefik dashboard.

The database volume is named postgres_data, so data survives a normal
container restart. Removing the volume removes the local database.

Stop the containers with:

~~~sh
docker compose down
~~~

Use docker compose down -v only when the local database should be deleted.

## Testing and code quality

The tests use a real PostgreSQL database. The simplest local workflow is to
run them in the application container after installing the development
dependencies:

~~~sh
docker compose exec web pip install -r requirements-dev.txt
docker compose exec web python -m pytest
docker compose exec web python -m ruff check .
docker compose exec web python -m black --check .
~~~

The same checks run in GitLab CI. The test fixture starts the application
lifespan, creates the schema if needed, and verifies the seeded user and the
health, readiness, and metrics behavior.

## Production options

There are two production paths:

1. Docker Compose can run the production image on one host.
2. The normal project deployment uses Argo CD to render the Helm chart and
   reconcile the staging and production k3s clusters from Git.

For the Compose path, fill in the production values in .env and start the
stack with:

~~~sh
docker compose -f docker-compose.prod.yml up -d --build
~~~

Production requires POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB,
APP_DOMAIN, TRAEFIK_DASHBOARD_DOMAIN, TRAEFIK_DASHBOARD_AUTH, and
ACME_EMAIL. ACME_CA_SERVER can point at the Let's Encrypt staging endpoint
while certificate issuance is being tested.

## Kubernetes deployment

The Helm chart is in helm/fastapi-app. It creates the application Deployment
and Service, PostgreSQL StatefulSet and Service, Ingress, HTTPS redirect
middleware, persistent volumes, backup CronJob, and the production
PodDisruptionBudget.

The [GitOps directory](gitops/README.md) declares what Argo CD reconciles.
CI still creates Secrets from protected variables and waits for the requested
image to become healthy; those credentials are not stored in Git.

The infrastructure and cluster bootstrap process is documented in:

- [Architecture](docs/architecture.md)
- [Environment strategy](docs/environment-strategy.md)
- [CI/CD](docs/ci-cd.md)
- [Infrastructure](docs/infrastructure.md)
- [Security](docs/security.md)
- [Data management](docs/data-management.md)
- [Observability](docs/observability.md)
- [Runbook](docs/runbook.md)
- [Verification matrix](docs/verification.md)

The current project documentation is indexed in [docs/README.md](docs/README.md).
The image and Compose design is explained in
[docs/containerization.md](docs/containerization.md).
