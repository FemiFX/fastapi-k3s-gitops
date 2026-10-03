# Data management

## Purpose

PostgreSQL holds the only application state that cannot be recreated from the
repository. The data design therefore covers persistence, backup, verification,
restore, and the limits of the recovery plan.

## Database storage

In Docker Compose, PostgreSQL uses the postgres_data or postgres_data_prod
volume. In Kubernetes, PostgreSQL runs as a one-replica StatefulSet with a
PersistentVolumeClaim.

A StatefulSet provides a stable Pod identity and a stable volume association.
The database Service is headless so the application can resolve the stable
database name. PostgreSQL data is stored below the PGDATA subdirectory of the
mounted volume.

The database is not exposed outside the cluster. Only the application and
backup workloads connect to it.

## Schema lifecycle

The application creates missing tables during startup through SQLAlchemy
metadata. It then creates the seed user test@test.com if it does not already
exist.

There is no migration tool. This keeps the example small, but it means schema
changes are not versioned or applied through a controlled migration sequence.
Any future schema change that could affect running replicas should introduce a
migration process before it is deployed.

## Local backup

The Helm chart creates a separate backup PersistentVolumeClaim and a nightly
CronJob. The default schedule is 02:15 UTC and the default retention is 14
days.

The backup Job:

1. runs pg_dump using the same PostgreSQL image version as the database;
2. writes to a file ending in .partial;
3. renames the file only after pg_dump completes;
4. checks the gzip archive;
5. checks that the dump contains table definitions;
6. removes files older than the retention period;
7. lists the files retained on the backup volume.

The backup volume has a Helm keep policy so uninstalling the release does not
delete the dumps automatically.

## Off-site backup

Production values enable a second container in the backup Pod. The dump runs
as an initContainer, then restic encrypts and uploads the backup directory to
Cloudflare R2.

The upload container:

- initializes the restic repository if needed;
- stores the dump using the release name as the restic host;
- tags snapshots as pgdump;
- checks a five-percent sample of remote data;
- lists the snapshots after upload.

The object-storage credentials are deliberately limited to reading and writing.
They cannot delete objects. Retention pruning is therefore performed manually
from a trusted machine with a separate privileged key.

The restic repository password is essential. Losing it makes the encrypted
repository unusable, so it must be kept in a credential store separate from
the cluster.

Staging leaves off-site backup disabled. It has no production data and does not
need to hold object-storage credentials.

## Restore procedures

### In-cluster restore

An in-cluster restore uses a short-lived Job that mounts the backup PVC and
connects to the PostgreSQL Service. The selected compressed dump is piped to
psql with ON_ERROR_STOP=1. This makes psql exit on the first SQL error instead
of printing an error and returning success.

The full command is in the [Helm backup reference](../helm/README.md).

### Off-site restore

If the node is lost, restic can restore a snapshot to a trusted machine
without the Kubernetes cluster. The resulting SQL archive can then be loaded
into a replacement PostgreSQL instance.

The restore is manual. It requires the repository address, repository password,
read credentials, a selected snapshot, and a PostgreSQL destination.

## Restore drill

The staging drill should:

1. record the current row count;
2. confirm the application is serving;
3. drop the users table deliberately;
4. confirm that /ready returns 503 and / returns an error;
5. restore the selected dump;
6. confirm the row count and application response.

The drill must never be run against production.

## Recovery guarantees and limitations

The design provides operational recovery, not full disaster recovery:

- local dumps protect against accidental table deletion and bad migrations;
- production off-site copies protect against loss of the database node;
- recovery is manual;
- PostgreSQL is not replicated;
- there is no point-in-time recovery;
- off-site retention is manual;
- the recovery time and recovery point targets still need to be recorded.
