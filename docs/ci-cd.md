# CI/CD

## Purpose

GitLab CI validates source changes, builds the production image, scans the
source and image, and deploys a known image version to the Kubernetes
environments.

The pipeline definition is in .gitlab-ci.yml. Jobs are grouped into five
stages:

1. quality;
2. test;
3. build;
4. scan;
5. deploy.

Scheduled pipelines are treated differently from normal code pipelines. They
recheck the deployed image without rebuilding or redeploying the application.

## Normal pipeline

### Quality

The lint job installs the development dependencies and runs Ruff and Black.
The configuration scan checks Helm and Terraform for unsafe settings. It
reports HIGH findings and blocks CRITICAL findings.

The secret scan searches the repository for credentials and blocks HIGH and
CRITICAL findings. A committed password or token is treated as an immediate
failure.

### Test

The test job runs in Python 3.11 and starts PostgreSQL 15 as a GitLab service
with the alias db. DATABASE_URL points at that service. This is required
because importing the application creates the async database configuration and
the test client runs the startup lifespan.

The tests cover:

- the liveness response;
- liveness while the database check is unavailable;
- successful readiness;
- failed readiness;
- readiness calling the schema check;
- metrics response format;
- request counters;
- exclusion of probe traffic;
- the seeded user;
- user response fields.

### Build

The production image is built from Dockerfile.prod. It is tagged as:

~~~text
$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
~~~

The short commit tag avoids the ambiguity of a moving latest tag. Images for
deployable branches are pushed to the GitLab Container Registry.

### Scanning

Three scan types answer different questions:

| Scan | Question |
| --- | --- |
| trivy config | Is the Helm or Terraform configuration unsafe? |
| trivy fs with the secret scanner | Has a credential been committed? |
| trivy image | Does the built image contain vulnerable packages? |

The image scan first prints all HIGH and CRITICAL findings. It then blocks on
findings that have a fix, while allowing unfixed findings through with
ignore-unfixed. Any intentional exception belongs in .trivyignore.yaml with a
reason and expiry date.

The scan produces a GitLab container-scanning report even when the job fails,
so the finding remains available for review.

### Deployment

The deployment job runs on the self-hosted runner tagged proxmox. It selects
the GitLab Agent context using the project path and agent name. No kubeconfig
is stored in the repository or in CI variables.

The agent access files are stored under .gitlab/agents/staging and
.gitlab/agents/production. Their ci_access sections state which GitLab project
may use each agent. They do not grant Kubernetes permissions. The permissions
are defined separately by the Ansible GitLab Agent role and its RBAC template.
Keeping project access and cluster permissions separate means that allowing a
pipeline to connect is not the same as allowing it to change every resource
in the cluster.

Before Helm runs, the job:

1. creates or updates app-secrets from the database CI variables;
2. creates or updates backup-offsite when off-site backup variables are set;
3. selects the environment values file;
4. sets the image repository and commit tag;
5. runs helm upgrade --install;
6. waits for the PostgreSQL StatefulSet rollout;
7. waits for the application Deployment rollout;
8. runs an internal health smoke test.

Helm is not given --wait. The local-path storage class binds some claims only
when a Pod mounts them. Waiting for every resource would make a healthy
application deployment appear to time out because a backup claim is waiting
for its first scheduled Pod. The explicit rollout checks wait for the
workloads that define application availability.

## Branch and environment rules

| Source | Result |
| --- | --- |
| Merge request | Quality, tests, build, configuration scan, and secret scan |
| main | Build, blocking image scan, automatic staging deployment |
| production | Build, blocking image scan, manual production deployment |
| Scheduled pipeline | Deployed-image scan only |

Production is not deployed merely because code reaches the production branch.
The manual job must be started explicitly.

## Scheduled image scan

An image can become vulnerable after it was built. A new CVE can be published
without any new commit. The scheduled scan checks the image associated with the
production branch again, using the same HIGH and CRITICAL gate.

The scheduled pipeline does not run the normal lint, test, build, or deploy
jobs. This prevents a vulnerability check from unexpectedly rebuilding or
redeploying production.

## Required CI/CD variables

Database variables are required for both deployment environments:

- POSTGRES_USER;
- POSTGRES_PASSWORD;
- POSTGRES_DB.

Production off-site backup support additionally requires:

- RESTIC_REPOSITORY;
- RESTIC_PASSWORD;
- R2_ACCESS_KEY_ID;
- R2_SECRET_ACCESS_KEY.

The registry variables and agent kubeconfig are provided by GitLab.

## Pipeline limitations

- The image is built and pushed before the image scan completes.
- The image scan gates fixable HIGH and CRITICAL findings, not findings with no fix.
- Configuration scanning reports HIGH findings but blocks CRITICAL findings.
- The current merge-request build rule says it should not push an image, but the
  build script still contains an unconditional docker push. This should be
  corrected before the pipeline is described as fully non-publishing for merge
  requests.
