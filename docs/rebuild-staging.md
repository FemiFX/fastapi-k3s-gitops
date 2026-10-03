# Rebuild Staging From Nothing

Destroy the staging VM completely and rebuild it. The point is not the rebuild;
it is finding out which parts of "it is all in code" are not true yet.

**Run this deliberately, with time to spare. Not the day before a demo.**

Production is never touched: every step is scoped to staging.

## Why bother

Three things in this project were believed and turned out to be false, each
found only by doing the thing rather than reasoning about it:

- Backups were a guess until one was restored. The drill also found a readiness
  probe that could not fail.
- The runbook's commands had never been run. Every `psql` example was broken.
- The host's firewall rules had never survived a reboot. They had been
  unloadable since the day they were written.

A rebuild is the same test applied to everything at once.

## Before you start

```sh
# You will need these to hand
echo $ARGOCD_REPO_USERNAME   # deploy token, read_repository
echo $ARGOCD_REPO_PASSWORD
```

**And a new GitLab Agent token, created before you start.** Operate >
Kubernetes clusters > `staging` > Access tokens > Create token. Get it now: the
destroy takes the old one with it, and the rebuild stalls three steps later
without it.

Confirm the thing you are about to prove is currently true, so a failure
afterwards is unambiguous:

```sh
ansible staging -m shell --become -a "k3s kubectl -n argocd get applications"
ansible staging -m shell --become -a "k3s kubectl -n staging get pods"
```

Note the time. The number that matters at the end is how long this took.

## The short way

Steps 2 to 5 below are what `scripts/bootstrap.sh` automates, including both
credentials:

```sh
export GITLAB_PAT=glpat-...            # api scope, Maintainer. Revoke afterwards.
export GITLAB_USERNAME=...
export ARGOCD_REPO_USERNAME=... ARGOCD_REPO_PASSWORD=...
export POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=...
export STAGING_MATTERMOST_WEBHOOK_URL=...

./scripts/bootstrap.sh staging
```

It exits non-zero unless the application answers `/health`.

**Do the long way at least once anyway.** The point of the drill is to find out
what breaks, and a script that hides each step also hides which one failed. Use
the script when you need the environment back; use the steps below when you are
testing whether you could get it back.

## 1. Destroy it


GitLab, on `main`: run **`infra:destroy:staging`** and set the variable

```
CONFIRM_DESTROY = destroy staging
```

The job refuses without it. It is scoped with `-target` to the staging VM, so
production and the CI runner are untouched.

Confirm it is really gone:

```sh
ssh <proxmox-ssh-user>@203.0.113.10 "qm list"
```

VM 202 should be absent.

## 2. Rebuild the machine

**`infra:plan`** on `main` will now propose creating one VM. Read the plan --
this is the moment to notice if it proposes anything else.

Then **`infra:apply`**, the manual button.

```sh
ssh <proxmox-ssh-user>@203.0.113.10 "qm list"        # 202 running
ansible staging -m ping                 # may take a minute while it boots
```

## 3. Configure it

**`infra:configure`** runs on the next push to `main`, or run it by hand:

```sh
cd infra/ansible
ansible-playbook site.yml --tags common,k3s --limit staging
```

Then the pieces that are deliberately not automatic:

```sh
ansible-playbook site.yml --tags agent --limit staging \
  -e gitlab_agent_token=<a new token from GitLab>

ansible-playbook site.yml --tags argocd --limit staging \
  -e argocd_repo_username=... -e argocd_repo_password=...
```

**The agent token is the honest manual step.** It is created in the GitLab UI
and cannot be recovered, so a rebuilt cluster needs a new one. Automating it
means holding a GitLab API token with Maintainer rights, which is a bigger
credential than the one it replaces.

Revoke the old token on the same screen. Its only copy lived in the cluster you
just destroyed, so nothing can use it -- which is exactly why leaving it active
is pointless risk.

### The trap: the agent will look like it is still there

Registration and credential are two different things, and only one of them was
in the cluster:

| | Where it lives | Survives a destroy |
| --- | --- | --- |
| The agent registration | In GitLab | **Yes** |
| The agent token | A Secret in the cluster, shown once | **No** |

So a pipeline will still print the context and switch to it happily:

```
$ kubectl config get-contexts
  oluwafemi.akinlosotu/fast-api-docker-traefik:staging   gitlab   agent:3175286
$ kubectl config use-context "$CI_PROJECT_PATH:$AGENT"
Switched to context ...
```

**Both of those are local operations against GitLab-side metadata.** They list
and select agents that *exist*; neither one proves an agent is connected. The
first command that actually needs the cluster is the first one that can fail,
and by then the failure looks like whatever that command was doing.

Skipping this step during the first drill cost three rounds of diagnosis,
because every symptom pointed somewhere else.

## 4. Let Argo CD do the rest

Within a few minutes:

```sh
ansible staging -m shell --become -a "k3s kubectl -n argocd get applications"
```

Expect `root-staging`, `fastapi-app`, `monitoring` and `monitoring-rules`,
progressing to Synced and Healthy.

### Then run a pipeline, because Argo CD does not create the Secrets

Argo CD reconciles everything in `gitops/`, and secrets are deliberately not in
there. They are created by `sync:staging`, so **a rebuilt cluster has workloads
that cannot start until a pipeline has run**:

```
staging-fastapi-app-657cb9fd78-qr4sj   0/1   CreateContainerConfigError
staging-fastapi-app-db-0               0/1   CreateContainerConfigError
```

`CreateContainerConfigError` almost always means a referenced Secret or
ConfigMap is missing. Confirm it rather than assuming:

```sh
ansible staging -m shell --become -a "k3s kubectl -n staging get secret app-secrets"
ansible staging -m shell --become -a "k3s kubectl -n staging describe pod -l app.kubernetes.io/name=fastapi-app | tail -20"
```

Run a pipeline on `main` and let `sync:staging` create them. It is not a
failure of the GitOps design -- a secret in git is worse -- but it is a real
ordering dependency, and the rebuild is what makes it visible.

The application then comes up **with an empty database**, because the schema is
created at startup (see ADR-018) and no data was restored. That is the next
step and it is the most important one.

## 5. Restore the data

A rebuilt cluster with an empty database is not a recovered service. Use the
restore procedure in [helm/README.md](../helm/README.md).

For staging this is optional -- there is nothing there worth keeping -- but
**do it anyway at least once**, because a restore into a freshly built cluster
is a different test from a restore into a running one. It is the one that
matters.

## 6. Reboot the host

**Do not skip this.** It is the step that found the last outage.

```sh
ssh <proxmox-ssh-user>@203.0.113.10 "reboot"
```

Wait -- a Dedibox takes five to ten minutes -- then check everything came back
without intervention:

```sh
curl -sI https://project.femidevops.abrdns.com/health | head -1
ansible staging -m shell --become -a "k3s kubectl -n staging get pods"
ssh <proxmox-ssh-user>@203.0.113.10 "iptables -t nat -S PREROUTING"
```

The port forwarding rules must be present. They were not, once, because they
had been saved in a form that could never be restored -- and nothing revealed
it until a reboot.

## 7. Write down what broke

The drill has failed in its purpose if nothing surprised you. Record each
surprise as a fix in code, not a note in a runbook: a step you had to remember
is a step that will be forgotten.

### Found so far

| Run | What broke | Fix |
| --- | --- | --- |
| First | `infra:configure` failed with `deployments.apps "traefik" not found`. On a cluster k3s had only just installed, Traefik had not finished installing, and `rollout status` errors immediately on a missing Deployment instead of waiting for it | `k3s_server` now waits for the Deployment to exist before waiting for its rollout |
| First | The `argocd` role failed with `No such file or directory: helm`. Three roles installed helm themselves; `argocd` and `cert_manager` assumed somebody else already had. On a long-lived machine somebody always had | A `helm` role, listed as a dependency by all five roles that shell out to it |
| First | `sync:staging` failed creating the app Secret: `Failed to negotiate output media type`. Client-side `kubectl apply` downloads the cluster's OpenAPI schema to validate, and the GitLab Agent proxy will not serve it in the format kubectl asks for | Both sync jobs now use `kubectl apply --server-side --force-conflicts`, so the API server merges and validates and nothing is downloaded |
| First | Every application pod sat in `CreateContainerConfigError` for nine hours. Argo CD had reconciled correctly; the Secrets it does not own had never been created, because the job that creates them was the one that failed above | Step 4 now says a pipeline must run, and says what the symptom looks like |
| First | Nine hours of that outage reached nobody. Staging has no Alertmanager receiver, deliberately -- so the alerts fired inside the cluster and stopped there. Not a bug; a decision whose cost was invisible until something actually broke | Staging now routes critical alerts to its own quiet Mattermost channel, via `api_url_file` and a Secret that CI creates |
| First | The agent token was not recreated, and nothing said so. GitLab keeps the registration, so the CI kubeconfig still listed the context and `use-context` still succeeded -- both GitLab-side metadata, neither proving a connected agent | The token is now in the "before you start" list, with a note that the context appearing proves nothing |
| First | The role reported "the agent is not installed" whenever `helm status` returned non-zero, which also covers "helm could not reach the cluster" | It now requires helm to have actually said `release: not found`, and quotes helm's own output either way |

Note what that one has in common with the rest of this project: the task had
run clean on every previous configure, because every previous configure ran
against a cluster that already had Traefik. **The rebuild is the only thing
that exercises the first five minutes of a cluster's life.**

## What this proves, and what it does not

**Proves:** the VM is reproducible from Terraform; k3s and the OS from Ansible;
the cluster's contents from git; the data from an off-site backup; and that the
host's configuration survives a power cycle.

**Does not prove:** that production can be rebuilt. Production has cert-manager,
a real certificate, a public DNS record, NAT rules pointing at its address, and
data that matters. The procedure is the same; the consequences are not.

**Still manual, and honestly so:**

- The Proxmox API token, created in the web UI
- The GitLab Agent token, created in the GitLab UI
- The decision to restore, and which snapshot

Every one of those hands over a credential or makes a judgement. That is where
a person belongs.
