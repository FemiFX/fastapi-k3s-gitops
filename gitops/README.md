# GitOps

What each cluster should contain, declared here and reconciled by Argo CD.

## How it fits together

```
gitops/apps/<environment>/        Applications, one per thing in the cluster
        |
        +-- the root Application (applied once by the argocd Ansible role)
                |
                +-- Argo CD reads this directory every few minutes
```

The root Application points at a directory of Applications. That is the
"app of apps" pattern, and it means rebuilding a cluster is: install Argo CD,
apply one object, wait.

## What Argo CD owns, and what it does not

| Thing | Owner |
| --- | --- |
| The application: Deployment, Service, Ingress, PDB, CronJob, PVC | Argo CD |
| cert-manager and its ClusterIssuers | Argo CD, once migrated |
| kube-prometheus-stack, ServiceMonitor, PrometheusRule | Argo CD, once migrated |
| `app-secrets`, `backup-offsite` | **CI**, pushed from protected variables |
| VMs, the OS, k3s itself, the host firewall | Terraform and Ansible |
| Argo CD itself | Ansible, once, as a bootstrap |

**Secrets stay with CI deliberately.** Anything that encrypts secrets inside the
cluster -- Sealed Secrets, for instance -- becomes unreadable when the cluster
is rebuilt, because the decryption key died with it. That defeats the point of
being able to rebuild. CI/CD variables outlive the cluster, so they are what a
rebuilt cluster is given.

The line to remember: **everything non-secret is pulled from git; secrets are
pushed by CI.**

## What changes about deploying

Before, the pipeline ran `helm upgrade` against the cluster. Now it builds the
image, scans it, and writes the new tag into `gitops/apps/<env>/values.yaml`,
then pushes. Argo CD notices the commit and reconciles.

Three things follow for free:

- **Rollback is `git revert`.** No guessing which pipeline to re-run.
- **The audit trail is the git history.** What ran on a given day is a commit.
- **CI holds no cluster credentials for deploys.** It only needs to push.

## Two switches worth understanding

Every Application here sets:

```yaml
syncPolicy:
  automated:
    selfHeal: true   # live drifted from git? put it back
    prune: true      # removed from git? delete it from the cluster
```

Without `selfHeal` Argo CD only *reports* drift and waits to be told. Without
`prune`, deleting a file leaves the object running in the cluster forever.

## Sync waves

Some things must exist before others -- cert-manager's CRDs before anything
creates a Certificate. The annotation orders them:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

Lower numbers go first. Anything unannotated is wave 0.
