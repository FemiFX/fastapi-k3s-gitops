# Containerization

## Purpose

The repository has two container images because development and production
have different needs. Development favors a short feedback loop. Production
favors a small, predictable, unprivileged runtime image.

Docker Compose describes how the local containers work together. Kubernetes
uses the production image but supplies the higher-level concerns: replicas,
service discovery, probes, persistent volumes, and rolling updates.

## Development image

Dockerfile builds the development image from Python 3.11 slim. It:

1. sets /app as the working directory;
2. enables unbuffered Python output;
3. installs requirements.txt;
4. copies the repository into the image.

The development Compose file bind-mounts the repository into /app. That means
source changes are visible inside the running container without rebuilding the
image. It is useful for development, but it is not a production isolation
boundary.

Compose supplies the application command. The web service waits for the db
hostname to accept connections and then starts Uvicorn. The database and web
containers are not published directly to the host. Traefik publishes port
8008 and forwards requests to the web service's internal port 8000.

The local request path is:

~~~text
http://fastapi.localhost:8008
  -> Traefik port 80
  -> web service port 8000
  -> FastAPI
~~~

The development Traefik dashboard is mapped to port 8081. It uses the Docker
provider and only discovers containers with the enable label. This keeps
unrelated containers out of the routing table.

## Production image

Dockerfile.prod starts from the official Python 3.11 slim image rather than a
web-server image that bundles its own process manager. The application is
served by one Uvicorn process per container. Kubernetes supplies replicas when
more process capacity is needed.

The production build:

- installs netcat-openbsd because the startup wrapper uses nc;
- upgrades operating-system and Python build packages during the image build;
- installs only the runtime requirements;
- removes pip, setuptools, and wheel after installation;
- removes stale third-party SBOM files;
- records the installed package list in the build log;
- copies the application and startup wrapper;
- creates fixed user and group ID 10001;
- changes ownership of the application directory;
- runs as user 10001;
- exposes port 8000;
- uses prestart.sh as its entrypoint;
- starts Uvicorn through python -m uvicorn.

Removing the package manager and build tools reduces the runtime attack
surface. The trade-off is that packages cannot be installed into a running
container. A new dependency requires a new image build.

The image listens on 8000 because a non-root Linux process cannot bind to a
port below 1024 without the net-bind-service capability. The Kubernetes
Service still provides port 80 inside the cluster and forwards to the named
container port 8000. This keeps the public routing contract separate from the
process privilege requirement.

## Startup wrapper

prestart.sh performs one small job: it waits until the configured PostgreSQL
host and port accept TCP connections, then replaces itself with the command
passed by the image or Compose.

The host defaults to db for Compose. Helm sets DB_HOST to the release-specific
database Service, such as prod-fastapi-app-db.

The wrapper checks that the database network endpoint is open. It does not
prove that the database is ready for SQL, that the credentials work, or that
the users table exists. Those stronger checks belong to the application
readiness endpoint and PostgreSQL probes.

Using exec for the final command matters. It makes Uvicorn the container's
main process, so it receives termination signals directly and exits with the
correct status.

## Compose and Kubernetes differences

| Concern | Docker Compose | Kubernetes and Helm |
| --- | --- | --- |
| Application process | web service command | Deployment and production image CMD |
| Service discovery | Docker DNS name db | ClusterIP Service with release-prefixed name |
| External routing | Traefik Docker labels | Traefik Ingress and Middleware resources |
| Scaling | One local web container | One staging or two production Pods |
| Health | Manual curl checks | Startup, liveness, and readiness probes |
| Database storage | Named Docker volume | StatefulSet volume claim |
| Configuration | Compose interpolation and .env | Helm values plus CI-created Secret |
| Delivery | docker compose up | Helm upgrade through GitLab CI |

The application code is the same. The orchestration layer changes around it.
This is why the internal application port and the DATABASE_URL format are kept
consistent across environments.

## Environment variables and interpolation

Compose expands variables before sending the configuration to the container.
The development file also supplies defaults so the stack can start with the
example environment file.

Production Compose uses required-variable syntax. If a password, hostname, or
certificate setting is missing, Compose stops before starting the stack. This
is safer than silently starting with a default production credential.

The Helm deployment does not pass database passwords through Helm values.
GitLab CI creates app-secrets with kubectl, and the Deployment reads the
Secret. This avoids putting credentials in chart values and Helm release
history.

## Line endings and executable permissions

The repository uses LF line endings for shell scripts and Dockerfiles. The
containers run Linux, so a CRLF shell script can make a valid command fail with
an invisible carriage-return character.

Dockerfile.prod also runs chmod +x on prestart.sh. Git stores executable mode,
but a Windows checkout does not always preserve it in the working tree. The
build makes the runtime requirement explicit.

## Build and inspect an image

Build the production image locally:

~~~sh
docker build -f Dockerfile.prod -t fastapi-docker-traefik:test .
~~~

Inspect its runtime user and entrypoint:

~~~sh
docker image inspect fastapi-docker-traefik:test
docker run --rm --entrypoint id fastapi-docker-traefik:test
~~~

The second command overrides the startup wrapper on purpose, so it can inspect
the image user without waiting for PostgreSQL. For a complete runtime check,
use Docker Compose instead.

The CI pipeline tags deployable images with the short commit SHA. A tag is
passed to Helm during deployment so an environment can be traced to a source
commit.

## Security boundary

The development image is a convenience image. It bind-mounts source code and
uses development defaults. The production image is the artifact scanned and
deployed to k3s.

Kubernetes adds the runtime controls that complement the image:

- runAsNonRoot and fixed UID 10001;
- read-only root filesystem;
- writable /tmp only;
- no privilege escalation;
- dropped Linux capabilities;
- RuntimeDefault seccomp profile;
- resource requests and limits;
- health probes;
- replica and rollout policy.

The image and the chart make related promises at two different layers. The
image defines how the process can run. The chart enforces the expected runtime
when the image is deployed.

## Further references

- [Application and API](application.md)
- [Architecture](architecture.md)
- [Security](security.md)
- [CI/CD](ci-cd.md)
- [Environment strategy](environment-strategy.md)
