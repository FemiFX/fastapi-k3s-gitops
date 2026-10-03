# Helm chart

Deployment definitions for the two k3s clusters, packaged as a Helm chart.

## Layout

```
fastapi-app/
  Chart.yaml                chart name and version
  values.yaml               defaults, shared by both environments
  values-staging.yaml       what staging overrides
  values-production.yaml    what production overrides
  templates/                the Kubernetes objects
```

## Why Helm

Helm renders templates into Kubernetes objects and records each install as a
numbered **release**. That gives three things plain manifests do not:

- `helm rollback` returns to the previous release in one command.
- `helm history` shows what was deployed and when.
- `helm upgrade --install` is one command whether the app is new or existing.

The cost is a templating layer between you and the YAML. Render it any time to
see exactly what will be applied:

```sh
helm template staging fastapi-app -f fastapi-app/values-staging.yaml
```

## Environment differences

| | staging | production |
| --- | --- | --- |
| Release name | `staging` | `prod` |
| Namespace | `staging` | `production` |
| App replicas | 1 | 2 |
| Database volume | 5 Gi | 10 Gi |
| Hostname | `staging.k3s.local` | `project.femidevops.abrdns.com` |
| Reachable from the internet | no | yes, ports 80/443 |

Two replicas in production mean a rolling update never drops to zero available
Pods, and the second node actually gets work.

Production uses the configured DNS hostname so the public entry point and the
certificate name remain stable. Let's Encrypt issues certificates for names,
not IP addresses.

## Design notes

**No secrets in this chart.** The templates refer to a Secret named
`app-secrets` by name only. The pipeline creates it from CI/CD variables before
installing. This matters with Helm specifically: Helm stores the values of every
release in the cluster, so a password passed through `--set` would sit in the
release history.

**PostgreSQL is a StatefulSet.** A Deployment treats Pods as interchangeable and
names them randomly. A StatefulSet gives a stable name and its own
PersistentVolume that survives restarts. A database needs both.

**`DB_HOST` is injected.** The chart prefixes resource names with the release
name, so the database Service is `staging-fastapi-app-db`, not `db`. The
container's `prestart.sh` waits on `$DB_HOST`, which the chart sets. It still
defaults to `db`, so Docker Compose keeps working unchanged.

**Probes.** `/health` is the liveness probe and must not touch the database,
because failure restarts the container. `/ready` is the readiness probe and does
check the database, because failure only removes the Pod from the Service.

## Installing by hand

The pipeline normally does this.

```sh
export KUBECONFIG=../infra/ansible/kubeconfig-prod-server.yaml
helm upgrade --install prod fastapi-app \
  --namespace production --create-namespace \
  --values fastapi-app/values-production.yaml \
  --set image.tag=sha-abc1234 \
  --wait
```

Undo a bad deploy:

```sh
helm -n production rollback prod
```

## Backups

A CronJob dumps the database nightly at 02:15 UTC to its own PersistentVolume,
keeps 14 days, and deletes older dumps.

The job does three things beyond running `pg_dump`:

- Writes to `.partial` and renames only on success, so a crash halfway leaves an
  obviously incomplete file rather than a truncated one that looks fine.
- Verifies the gzip archive and checks it contains table definitions. A dump
  that restores nothing is worse than no dump, because it is believed.
- Uses the same image as the database, so `pg_dump` always matches the server
  version. A client older than the server refuses to dump.

### A note on quoting

Every command below runs a shell **inside** the container, in single quotes:

```sh
kubectl -n staging exec staging-fastapi-app-db-0 --   sh -c 'psql -U "$POSTGRES_USER" ...'
```

Without the `sh -c`, your own shell expands `$POSTGRES_USER` before kubectl
sends anything. On a machine where it is not set that becomes empty, psql falls
back to your login name, and you get `FATAL: role "root" does not exist`. The
variables live in the container, so the container's shell has to be the one
that reads them.

### Run a backup now, rather than waiting for tonight

```sh
kubectl -n staging create job --from=cronjob/staging-fastapi-app-backup manual-1
kubectl -n staging logs job/manual-1
```

The log ends with `Verified /backups/<db>-<stamp>.sql.gz` and a listing.

The claim is `Pending` until this first runs. That is normal: the `local-path`
class binds a volume only when a pod mounts it. It is also why the deploy waits
on the workloads rather than using `helm --wait` — see `.gitlab-ci.yml`.

### Restore

Dumps are written with `--clean --if-exists`, so they restore over a database
that already has data. The dump lives on the backup volume, which nothing
mounts by default, so the restore runs as a Job that mounts it:

```sh
cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: restore
  namespace: staging
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restore
          image: postgres:15-alpine
          env:
            - name: PGHOST
              value: staging-fastapi-app-db
            - name: PGUSER
              valueFrom: {secretKeyRef: {name: app-secrets, key: POSTGRES_USER}}
            - name: PGPASSWORD
              valueFrom: {secretKeyRef: {name: app-secrets, key: POSTGRES_PASSWORD}}
            - name: PGDATABASE
              valueFrom: {secretKeyRef: {name: app-secrets, key: POSTGRES_DB}}
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              LATEST=$(ls -1t /backups/*.sql.gz | head -1)
              echo "Restoring ${LATEST}"
              gzip -dc "${LATEST}" | psql -v ON_ERROR_STOP=1
              echo "Rows restored:"
              psql -tAc 'select count(*) from users;'
          volumeMounts:
            - {name: backups, mountPath: /backups}
      volumes:
        - name: backups
          persistentVolumeClaim: {claimName: staging-fastapi-app-backups}
YAML

kubectl -n staging wait --for=condition=complete job/restore --timeout=120s
kubectl -n staging logs job/restore
```

`ON_ERROR_STOP=1` is not optional. Without it psql prints errors, carries on to
the end, and exits 0 — a restore that half-failed would look like a success.

For production, replace `staging` with `production` and `staging-fastapi-app`
with `prod-fastapi-app`, and pick the dump explicitly rather than taking the
newest.

### Testing a restore, which is the part that counts

An untested backup is a guess. This drill has been run on **staging**; never
run it on production.

```sh
# 1. Baseline
kubectl -n staging exec staging-fastapi-app-db-0 --   sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from users;"'

kubectl -n staging run probe --image=curlimages/curl:8.10.1 --rm -i   --restart=Never --quiet -- -s -o /dev/null -w '%{http_code}
' --max-time 10   http://staging-fastapi-app.staging.svc.cluster.local/

# 2. Break it on purpose
kubectl -n staging exec staging-fastapi-app-db-0 --   sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "drop table users;"'

# 3. Confirm the app notices: / returns 500, /ready returns 503

# 4. Run the restore Job above

# 5. Confirm: row count matches step 1, / returns 200 again
```

Step 3 is worth pausing on, because the first run of this drill got it wrong.
`/ready` used to run `SELECT 1`, which only proves the connection is open — so
with the table gone the app reported **ready** and served 500s. The probe now
reads from the table it serves, which is what makes step 3 meaningful. A
readiness check that cannot fail is decoration.

### Off-site copies

Production ships each dump to Cloudflare R2 with restic, as the second stage of
the same CronJob. The dump runs as an initContainer and the upload as the
container, so the job succeeds only if the backup both worked and left the
node.

restic rather than a plain copy because it encrypts before anything leaves the
cluster, deduplicates, and can verify the remote repository:

```
restic backup --host <release> --tag pgdump /backups
restic check --read-data-subset=5%
```

**The bucket credentials have no delete permission, deliberately.** A backup job
that can delete backups is the first thing an attacker reaches for, so
`restic forget --prune` is not run from the cluster. Expiry is a manual
operation from a trusted machine with a second, privileged key:

```sh
export RESTIC_REPOSITORY='s3:https://<account>.r2.cloudflarestorage.com/<bucket>'
export RESTIC_PASSWORD=...
export AWS_ACCESS_KEY_ID=...      # the admin key, not the cluster's
export AWS_SECRET_ACCESS_KEY=...

restic forget --tag pgdump --keep-daily 14 --keep-weekly 8 --prune
```

### Restoring from off-site

This is the drill that matters, because it is the one you would run after
losing the node. It needs only restic, the repository password and a read key.

```sh
restic snapshots --tag pgdump                    # pick one
restic restore <snapshot-id> --target ./restored # writes ./restored/backups/...
ls -lh ./restored/backups

# then load it into a database, exactly as with a local dump
gzip -dc ./restored/backups/<db>-<stamp>.sql.gz   | psql -h <host> -U <user> -d <db> -v ON_ERROR_STOP=1
```

Two things to notice. The password is not stored anywhere in the cluster except
the Secret the pipeline builds, so **losing it loses the backups** — keep it
where you keep the rest of your credentials, not only in GitLab. And the
restore does not need the cluster at all, which is the point of an off-site
copy.

### Known limitations, worth stating rather than hiding

- The local backup volume is on the **same node** as the database, so it alone
  protects against a dropped table, not against losing the node. Production
  additionally ships every dump to object storage; staging does not, and has
  nothing worth shipping.
- **Retention off-site is manual**, because the cluster's credentials cannot
  delete. That is the intended trade.
- Restores are manual and documented, not automated.
- Staging has no off-site copy, so its local backup protects against an
  application or schema mistake but not loss of the staging node. Production
  adds the restic and Cloudflare R2 path described above. This is still a
  manually operated disaster-recovery path: the repository password must be
  preserved and restore drills must be recorded.
