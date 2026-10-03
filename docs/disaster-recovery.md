# Disaster Recovery

What is protected, how long recovery takes, and what to do in each case.

The command-level procedures live elsewhere and are not repeated here:

- Database backup and restore: [../helm/README.md](../helm/README.md)
- Rebuilding a whole environment: [rebuild-staging.md](rebuild-staging.md)
- Day-to-day operations: [runbook.md](runbook.md)

## The two numbers

**RPO (Recovery Point Objective)** — how much data a failure can cost.
**RTO (Recovery Time Objective)** — how long service is gone.

| | Target | Where the number comes from |
| --- | --- | --- |
| RPO | **24 hours** | The dump runs nightly at 02:15 UTC. A failure at 02:00 loses a day of writes |
| RTO, bad release | **~5 minutes** | A git revert, then Argo CD's 180s poll plus a rolling update |
| RTO, database restore | **~5 minutes** | The restore Job itself is seconds; the time is pulling the postgres image and waiting on the Job |
| RTO, full environment rebuild | **~12 minutes** | Timed pipeline stages, broken down below |

**Deciding is not the same as restoring.** Choosing which dump to use can take
longer than applying it, especially if the corruption is old enough to be in
several dumps. That is a human decision and it is not counted in the RTO
above; it is called out in scenario 3 instead. Mixing the two makes the system
look ten times slower than it is.

A tighter RPO needs continuous archiving (WAL shipping), which is the first
thing to add if the data ever justifies it. Restore speed cannot improve it —
only backing up more often can.

### Where the rebuild figure comes from

`scripts/bootstrap.sh` has eleven steps. Four of them can take real time, and
all four are dominated by copying or downloading rather than by logic.

| Step | Time | Source |
| --- | --- | --- |
| Preflight, mint both tokens, `terraform init` | ~60s | Estimate: three checks and two API calls |
| `terraform plan` | **14s** | Measured |
| `terraform apply` — clone the template, boot | **59s** | Measured |
| cloud-init finishing, wait for SSH | ~90s | Estimate |
| Ansible: common + k3s | **2m 26s** | Measured (`infra:configure`) |
| Ansible: GitLab Agent + Argo CD | ~2m | Estimate: two helm installs and image pulls |
| Seed the Secrets | ~10s | Estimate: two `kubectl apply` |
| Argo CD fills the cluster | **3m 30s** | Measured |
| Rollout wait + smoke test | ~30s | Estimate |
| **Total** | **~12 minutes** | 7m 9s of it measured |

Round it to **15 minutes** when quoting, to leave room for the estimates.
Image pulls dominate the two longest steps, so a warm image cache makes it
faster and a cold one slower.

## What exists to recover from

| Copy | Where | Covers | Retention |
| --- | --- | --- | --- |
| PostgreSQL PVC | The node's disk | Nothing — this is the thing that fails | — |
| Nightly `pg_dump` | A separate PVC on the same node | A dropped table, a bad migration, an application bug | 14 days |
| restic snapshot | Cloudflare R2, off-site | The node, the host, the whole platform | Manual pruning |
| The platform itself | Git | Everything except data | Full history |

The important line is the third. A dump on the same disk as the database
covers human error and nothing else — if the disk goes, both go together.
The off-site copy is what makes the other rows survivable.

**The R2 key can write and list but cannot delete.** Ransomware and mistakes
both delete backups, so the credential held by the cluster cannot destroy the
copies it writes. Pruning is therefore a manual job from a trusted machine —
a deliberate consequence, not an oversight.

## Scenarios

Ordered from most likely to least.

### 1. A bad release

**Detected by:** the smoke test in `sync:*`, or `ApplicationNoReadyReplicas`.

**Recovery:** revert the commit that changed `image.tag` and push. Argo CD
reconciles the cluster back. No data involved, nothing to restore.

**RTO:** about 5 minutes. Argo CD polls every 180 seconds, so most of that is
waiting for it to notice; a webhook would make it near-instant. This is the
case the whole GitOps arrangement optimises for.

### 2. A pod or a single node fails

**Detected by:** `ApplicationNoReadyReplicas`, `DatabaseDown`, or the Watchdog
stopping.

**Recovery:** none needed for the application — a second replica is already
serving and Kubernetes reschedules the lost one.

**Caveat worth knowing before it happens:** losing **prod-agent** is
survivable; losing **prod-server** is not. The host NATs 80/443 to
`10.10.10.30` and the control plane lives there, so its loss stops traffic
even though pods survive on prod-agent. The two nodes are not interchangeable.

**Also check:** which node PostgreSQL's `local-path` volume is pinned to. If
it is on the lost node, this scenario becomes scenario 3.

```sh
kubectl -n production get pods -o wide
```

### 3. Data loss — dropped table, bad migration, corruption

**Detected by:** `/ready` failing (it queries the model, not `SELECT 1`), or a
user noticing.

**Recovery:** restore the most recent good dump into the running cluster. The
procedure is in [../helm/README.md](../helm/README.md).

**RPO:** up to 24 hours. **RTO:** about 5 minutes once you know which dump you
want — the Job's own timeout is 120 seconds, and most of the time goes on
pulling the `postgres:15-alpine` image.

**The choosing is the slow part, and it is not mechanical.** Restoring the
newest dump is usually right and occasionally wrong: if the corruption
happened three days ago and has been dumped nightly since, the newest dump
contains it. Budget for that separately from the restore itself.

### 4. A cluster is lost

**Detected by:** everything at once, or a failed `terraform apply`.

**Recovery:** rebuild it. [rebuild-staging.md](rebuild-staging.md) is the
procedure and it has been executed; `scripts/bootstrap.sh` automates most of
it. Then restore the database into the fresh cluster.

**RTO:** about 12 minutes for the rebuild, plus the restore. See the breakdown
above for where the time goes.

**Restoring into a freshly built cluster is a different test** from restoring
into a running one, and it is the one that matters here. Both have been done.

### 5. The Proxmox host is lost

The honest scenario, and the one that defines the limits of this design.

**Everything is gone at once:** both clusters, all four VMs, the local dumps,
the ZFS pool. What survives is off the machine entirely — the git repository,
the GitLab CI/CD variables, the Terraform state, and the restic repository in
R2.

**Recovery:**

| | Step | Time |
| --- | --- | --- |
| 1 | Obtain a host running Proxmox | **Outside our control** |
| 2 | `infra/scripts/build-template.sh` — build the cloud-init template Terraform clones from | ~5 min, mostly downloading the cloud image |
| 3 | Update the endpoint and node name in `infra/terraform/variables.tf` | ~1 min |
| 4 | `scripts/bootstrap.sh production` with a fresh `GITLAB_PAT` | ~12 min |
| 5 | Restore from R2 | ~10 min |
| 6 | Repoint DNS at the new address | Minutes, plus TTL |

**RTO: roughly 30 minutes of work, plus however long a host takes to obtain.**

Those two are worth quoting separately rather than added together. The work is
half an hour and it is fully scripted; the wait belongs to the hosting
provider and no design choice of ours shortens it. A single merged figure
makes the platform look slow when the platform is not the slow part.

Step 2 is easy to forget. Terraform clones VM 9000, and a brand-new host does
not have it — the bootstrap would fail at `terraform apply` with a missing
template. It is scripted, but it is a prerequisite, not part of the bootstrap.

**This path has never been executed end to end.** It is reasoned, and each
piece has been exercised separately — the rebuild drill, the off-site restore,
the bootstrap script. By this project's own standard that makes it a plausible
claim rather than a proven one, and it is stated that way on purpose.

### 6. Backups themselves fail

The failure nobody notices, so it is alerted on three ways:

| Alert | Catches |
| --- | --- |
| `BackupJobFailed` | A recent run failed |
| `BackupStale` | Nothing has succeeded in 26 hours — covers a run of failures |
| `BackupMetricMissing` | No backup Jobs reported at all — covers the CronJob being deleted |

The third uses `absent()`. Without it, deleting the CronJob would look exactly
like everything being fine, because an alert cannot fire on data it never
receives.

## What is not protected against

Stated rather than discovered under pressure.

| Not covered | Consequence | What it would take |
| --- | --- | --- |
| Writes since the last nightly dump | Up to 24 hours of data | WAL archiving to R2 |
| Loss of prod-server | Traffic stops even though prod-agent survives | A second entry point, which needs a second host |
| Loss of the Proxmox host | Full outage until a new host exists | A second host, or a cloud region |
| Loss of the R2 account | Off-site copies gone | A second provider |
| No hypervisor console access | Cannot recover a host that will not boot | Provider support ticket — the console belongs to the training provider |

The first and last are the ones to mention unprompted. The console limitation
is real: if the firewall ever locked us out completely, recovery would be a
support request rather than a keyboard.

## Drills, and why they are the point

| Drill | Status | What it found |
| --- | --- | --- |
| Restore into a running cluster | Done | A readiness probe that returned 200 with the table dropped |
| Restore into a rebuilt cluster | Done | — |
| Full staging rebuild | Done | Five defects, all fixed in code — see [rebuild-staging.md](rebuild-staging.md) |
| Host reboot | Done | Port-forwarding rules that had never been loadable |
| Full host loss | **Not done** | — |

Every row that says "done" moved a claim from plausible to proven, and three
of the five found something. That is the argument for scheduling them rather
than trusting the design.

An untested backup, an unexecuted runbook, an unrebooted host and an unrebuilt
cluster are the same kind of claim: reasonable, and unverified.
