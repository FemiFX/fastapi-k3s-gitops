# Architecture Diagrams

Diagrams of the platform, from the host down to a single deployment. GitLab
renders them directly; no tooling needed.

---

## 1. One host, four VMs

```mermaid
flowchart TB
  net(["Internet"])

  subgraph host["Proxmox VE host — 8 vCPU · 94 GB RAM · 5.25 TB ZFS"]
    direction TB
    fw["Host firewall — default deny<br/>22 · 8006 · 80 · 443 · ICMP"]
    dnat["pve-portforward script<br/>DNAT 80/443 + hairpin + MASQUERADE<br/>systemd unit, PartOf pve-firewall"]

    subgraph lan["vmbr1 — 10.10.10.0/24 · gateway 10.10.10.1"]
      direction LR
      r["ci-runner · VM 201<br/>10.10.10.10<br/>2 vCPU · 4 GB · 40 GB"]
      s["staging · VM 202<br/>10.10.10.20<br/>2 vCPU · 6 GB · 40 GB"]
      p1["prod-server · VM 203<br/>10.10.10.30<br/>2 vCPU · 6 GB · 40 GB"]
      p2["prod-agent · VM 204<br/>10.10.10.31<br/>2 vCPU · 4 GB · 40 GB"]
    end
  end

  net --> fw
  fw --> dnat
  dnat -- "80, 443" --> p1
  p1 <-- "cluster traffic" --> p2
```

Public traffic reaches exactly one VM. Every other machine is reached by SSH
through the host, which is why every Ansible connection uses a ProxyJump.
The port forwarding is one script, run by Ansible and by a systemd unit at
boot, so the rules that are tested are the rules that load. A saved
netfilter-persistent ruleset failed to load on every boot and nobody knew
until the first reboot.

---

## 2. Two separate clusters

```mermaid
flowchart TB
  subgraph stg["staging — 10.10.10.20 · single node"]
    direction TB
    sa["ns: staging<br/>fastapi-app · PostgreSQL StatefulSet<br/>backup CronJob"]
    sm["ns: monitoring<br/>Prometheus · Alertmanager · Grafana<br/>Loki · Alloy"]
    sg["ns: argocd · ns: gitlab-agent"]
  end

  subgraph prd["production — 10.10.10.30 + 10.10.10.31 · two nodes"]
    direction TB
    pa["ns: production<br/>fastapi-app ×2, spread across nodes<br/>PodDisruptionBudget · PostgreSQL StatefulSet"]
    pm["ns: monitoring<br/>Prometheus · Alertmanager · Grafana<br/>Loki · Alloy on both nodes"]
    pc["ns: cert-manager<br/>Let's Encrypt issuers"]
    pg["ns: argocd · ns: gitlab-agent"]
  end

  ing(["project.femidevops.abrdns.com"]) -- "HTTPS, real certificate" --> pa
```

Two application replicas remove the most common cause of downtime: one pod
dying. They change nothing about the database, the control plane, or the host.
The host NATs 80/443 to one address, so that node is still the only way in.

---

## 3. How code reaches production

```mermaid
flowchart LR
  dev(["git push"]) --> gl["GitLab"]

  subgraph pipe["Pipeline — self-hosted runner on 10.10.10.10"]
    direction TB
    q["quality<br/>ruff · black"]
    t["test<br/>pytest against real PostgreSQL"]
    b["build<br/>image tagged :short-sha"]
    sc["scan<br/>Trivy: image · config · secrets"]
    rl["release<br/>rewrite image.tag in gitops/"]
    q --> t --> b --> sc --> rl
  end

  gl --> pipe
  rl -- "commit + push" --> repo[("gitops/apps/…/fastapi-app.yaml")]

  repo -. "polled every few minutes" .-> argo["Argo CD<br/>inside the cluster"]
  argo -- "renders chart, applies diff" --> pods["fastapi-app pods"]

  sync["sync job<br/>creates Secrets<br/>waits for the tag to be running<br/>runs a smoke test"]
  pipe --> sync
  sync -. "via GitLab Agent" .-> pods
```

Solid lines are pushes; dotted lines are pulls. Nothing outside the cluster
holds a credential that can change it — Argo CD and the GitLab Agent both
connect outward. The sync job exists because pushing a commit is a request,
not a result: it polls until the running image is the requested one, then
curls the service. Staging tracks `main`; production tracks the `production`
branch, so promotion is a merge and rollback is `git revert`.

---

## 4. What Argo CD manages, and what CI creates

```mermaid
flowchart TB
  root["root Application<br/>installed once by Ansible"]
  root --> a1["fastapi-app<br/>releaseName: staging"]
  root --> a2["monitoring<br/>kube-prometheus-stack 89.2.2"]
  root --> a3["monitoring-rules<br/>sync-wave 1"]
  root --> a4["loki 7.3.0"]
  root --> a5["alloy 1.12.1 · sync-wave 1"]

  ci["GitLab CI — sync job"]
  ci -- "app-secrets" --> se1[/"ns: staging"/]
  ci -- "alertmanager-mattermost<br/>grafana-admin" --> se2[/"ns: monitoring"/]

  a1 --> se1
  a2 --> se2
  a4 --> se2
  a5 --> se2
```

Production's directory holds `fastapi-app`, `loki` and `alloy`; its Prometheus
stack is still installed by the Ansible `monitoring` role rather than Argo CD.

Secrets are deliberately outside `gitops/`: a secret in git is a secret
published, and anything that decrypts secrets *inside* the cluster dies with
the cluster, which defeats being able to rebuild it. The first rebuild drill
showed the cost: Argo CD reconciled perfectly and every pod sat in
`CreateContainerConfigError` for nine hours, because the Secret they all
reference is created by a pipeline that had failed. Argo CD guarantees what
is in `gitops/` and nothing else.

---

## 5. Metrics, logs and alerts

```mermaid
flowchart LR
  app["fastapi-app<br/>/metrics"]
  ksm["kube-state-metrics<br/>object state"]
  node["node-exporter<br/>host metrics"]

  app -- "scraped" --> prom["Prometheus<br/>7-day retention"]
  ksm -- "scraped" --> prom
  node -- "scraped" --> prom

  logs[/"/var/log/pods<br/>on the node"/] --> alloy["Alloy<br/>DaemonSet"]
  alloy -- "labels: namespace, pod,<br/>container, app" --> loki["Loki<br/>7-day retention"]

  prom --> graf["Grafana"]
  loki --> graf

  prom -- "PrometheusRule" --> am["Alertmanager"]
  am -- "critical only" --> mm1["Mattermost<br/>staging channel"]
  am -- "everything, grouped" --> mm2["Mattermost<br/>production channel"]
  am -- "Watchdog heartbeat" --> hc["External ping service<br/>alerts when it STOPS"]
```

The Watchdog fires constantly, on purpose, to a service outside the cluster
that alerts when the heartbeat stops. Without it, a dead monitoring stack
looks the same as a healthy platform. Alerts cover symptoms (no ready
replicas, no recent backup, database down), not causes (CPU, memory,
restarts); causes belong on the dashboard.

---

## 6. Where credentials live

```mermaid
flowchart LR
  subgraph out["Outside"]
    gl["GitLab.com<br/>CI/CD variables · Terraform state"]
    r2["Cloudflare R2<br/>write-only key"]
  end

  subgraph in["Inside the private network"]
    agent["GitLab Agent<br/>outbound wss to kas.gitlab.com"]
    argo["Argo CD<br/>outbound https to GitLab"]
    bk["backup CronJob<br/>restic"]
  end

  agent -. "opens the connection" .-> gl
  argo -. "opens the connection" .-> gl
  bk -. "pushes snapshots" .-> r2
```

| Credential | Lives in | Scoped to |
| --- | --- | --- |
| Proxmox API token | GitLab CI/CD variable | Terraform's own PVE user |
| Terraform state auth | `CI_JOB_TOKEN`, per job | Nothing long-lived |
| GitLab Agent token | A Secret inside each cluster | One cluster |
| Agent RBAC | Role, not ClusterRole | One namespace, plus two named Secrets in `monitoring` |
| CI SSH key | Protected CI/CD variable | Separate from the operator's key |
| R2 backup key | Secret in `production` | Write and list — **cannot delete** |

The R2 key cannot delete. Ransomware and mistakes both delete backups, so
the off-site copy is written with a key that cannot destroy it. Pruning is
manual from a trusted machine as a consequence.

---

## 7. Rebuilding staging from scratch

```mermaid
flowchart TB
  d["infra:destroy:staging<br/>manual · main only · -target the staging VM<br/>requires typing: destroy staging"]
  t["terraform apply<br/>VM 202 from the cloud-init template"]
  a["ansible-playbook --tags common,k3s<br/>then agent, then argocd"]
  g["Argo CD pulls the rest<br/>app · monitoring · loki · alloy"]
  p["a pipeline runs<br/>creates the Secrets nothing else owns"]
  rs["restore the database<br/>a judgement, not a step"]
  rb["reboot the hypervisor<br/>the step that found the last outage"]

  d --> t --> a --> g --> p --> rs --> rb
```

The first run of this drill found five defects, every one invisible on a
machine that had been alive for weeks — a rollout wait that assumed Traefik
already existed, a missing `helm` two roles had silently relied on, a kubectl
apply the agent proxy refused, workloads that could not start without CI's
Secrets, and an agent token that died with the cluster while GitLab kept the
registration. All five are fixed in code; the list lives in
[rebuild-staging.md](rebuild-staging.md).

---

## 8. Backups and what each copy protects

```mermaid
flowchart LR
  db[("PostgreSQL PVC<br/>node disk")]
  db -- "pg_dump nightly 02:15 UTC" --> dump[("Dump PVC<br/>same node · 14 days")]
  dump -- "restic, encrypted" --> r2[("Cloudflare R2<br/>off-site")]

  dump -. "restores" .-> c1["Dropped table<br/>bad migration<br/>application bug"]
  r2 -. "restores" .-> c2["Lost node<br/>lost cluster<br/>lost host"]

  key["R2 key: write + list<br/>NO delete"] --> r2
```

A dump on the same disk as the database covers human error and nothing else —
if that disk goes, both go together. The off-site copy is what makes the
second column survivable. The R2 credential cannot delete, so the cluster
that writes the backups cannot destroy them; pruning is a manual job from a
trusted machine as a result.

---

## 9. Recovery paths

```mermaid
flowchart TB
  f{"What was lost?"}

  f -- "A bad release" --> r1["git revert the image tag<br/>Argo CD reconciles<br/><b>~5 min</b> (180s poll + rollout)"]
  f -- "A pod, or prod-agent" --> r2["Nothing to do<br/>second replica serving<br/><b>~1 min</b> for endpoints to update"]
  f -- "Data" --> r3["Restore a dump into the<br/>running cluster<br/><b>~5 min</b> · RPO up to 24h"]
  f -- "A cluster" --> r4["scripts/bootstrap.sh<br/>then restore the database<br/><b>~12 min</b> + restore"]
  f -- "The Proxmox host" --> r5["build-template, bootstrap,<br/>restore from R2, repoint DNS<br/><b>~30 min of work</b><br/>+ waiting for a host"]

  r5 -. "never executed end to end" .-> note["Reasoned, not proven"]
```

The rebuild figure is built from timed pipeline stages: `terraform plan` 14s,
`terraform apply` 59s, Ansible common and k3s 2m 26s, Argo CD filling the
cluster 3m 30s, plus about five minutes of smaller steps. Image pulls dominate
the two longest of those. Full breakdown, and which parts are measured rather
than estimated, in [disaster-recovery.md](disaster-recovery.md).

Three points the diagram makes that are easy to miss. Losing **prod-agent** is
survivable and losing **prod-server** is not, because the host NATs 80/443 to
that node and the control plane lives there. The host-loss figure counts only
the work — obtaining a host is the provider's time and no design choice of
ours shortens it. And that path is the only one never carried out, which is
why it is drawn differently.

**Deciding is not included in any of these.** Choosing which dump to restore
can take longer than the restore, and that is a human judgement rather than a
system property.

---

## 10. What is not built, and why

These are decisions, not gaps. Each one was made for a reason.

| Not built | Because |
| --- | --- |
| Database HA | A single host cannot provide it; a replica on the same machine protects against nothing that matters |
| TLS on staging | Staging is not reachable from the internet |
| Automatic off-site pruning | The cluster's bucket key cannot delete, on purpose |
| Logs on production | The collector runs as root to read host files; staging carries that risk first |
| Blue/green or canary | Rolling updates with a readiness probe and a disruption budget are enough at this size |
| A hypervisor console | Not available — it belongs to the provider. A real limitation, stated rather than discovered under pressure |
