# Observability

## Purpose

Observability provides evidence about whether the application is alive,
whether it can serve requests, what traffic it receives, and whether the
platform is meeting its operational expectations.

## Application signals

The application exposes three operational endpoints:

- /health confirms that the process and event loop respond;
- /ready confirms that the PostgreSQL-backed schema can be queried;
- /metrics exposes Prometheus text-format metrics.

The instrumentation records request counts, durations, and response sizes.
Probe endpoints are excluded because Kubernetes calls them frequently and they
would obscure real application traffic.

Readiness failures are logged with the original exception while the HTTP
response uses the stable message database not ready. This gives operators
diagnostic information without exposing database details to callers.

## Monitoring stack

The Ansible monitoring role installs kube-prometheus-stack in the monitoring
namespace. The stack contains:

- Prometheus for scraping and time-series storage;
- Alertmanager for grouping and routing alerts;
- Grafana for dashboards;
- node-exporter for node metrics;
- kube-state-metrics for Kubernetes object state.

Prometheus retains seven days of data by default. Prometheus, Alertmanager,
and Grafana use local-path PersistentVolumeClaims.

The k3s-specific configuration disables scrapers for separate
controller-manager, scheduler, kube-proxy, and etcd processes because k3s
combines those functions and does not expose them as independent endpoints.

## Application discovery

The monitoring role creates a ServiceMonitor in the monitoring namespace. Its
namespace selector points at the application namespace and its label selector
finds the FastAPI Service. Prometheus scrapes the named http port at /metrics
every 30 seconds.

The role confirms the target through the Prometheus API and confirms that the
PrometheusRule loaded. This matters because Kubernetes can accept a
ServiceMonitor even when Prometheus is not selecting it.

## Alerts

The application-specific rule file contains:

| Alert | Meaning |
| --- | --- |
| BackupJobFailed | A backup Job reported failure |
| BackupStale | No successful backup exists within the configured age |
| BackupMetricMissing | No completed backup metric is being reported |
| ApplicationNoReadyReplicas | The application Deployment has no available replicas |
| ApplicationTargetDown | Prometheus cannot scrape the application |
| DatabaseDown | The PostgreSQL StatefulSet has no ready replica |

The standard kube-prometheus-stack rules provide additional node and
Kubernetes alerts. Alerts are grouped by alert name and namespace when a
notification receiver is configured.

## Alert delivery

The optional alert configuration sends notifications to a Mattermost incoming
webhook using Alertmanager's Slack-compatible configuration. Resolved alerts
are sent as well.

The Watchdog alert can be routed to a Healthchecks.io ping URL. Watchdog is
expected to fire continuously. The external check becomes unhealthy when those
pings stop, which covers failure of Prometheus, Alertmanager, or the node
hosting them.

Alert delivery should be tested deliberately. A configured webhook is not
evidence that the route works until a test alert is visible in the channel.

## Accessing Grafana

Grafana is a ClusterIP service. It is not exposed through the public Ingress.
The monitoring role prints an SSH and kubectl port-forward path after
installation. The connection should be made through the Proxmox jump host.

## Logging

The application writes readiness failures to its container log. Production
Compose enables Traefik access logs. Kubernetes logs can be inspected with
kubectl.

Loki is installed on staging. Grafana Alloy runs as a DaemonSet, reads the
container log files the kubelet writes under /var/log/pods, labels each stream
with namespace, pod, container and app, and pushes to Loki. Logs are queried in
Grafana with LogQL and retained for seven days, matching Prometheus.

Reading files rather than streaming from the Kubernetes API is deliberate: a
file outlives the container that wrote it, so a pod that crashed or a backup
Job that ran for nine seconds is still collectable.

Loki indexes labels, not log content. That is what allows it to run alongside
everything else on a 6 GB node, and it is why the label set is deliberately
small -- a high-cardinality label such as a request id would create one stream
per value.

Production is not collected yet. The collector must run as root to read
root-owned files on the host, and that risk is taken on staging first.

## Monitoring limitations

- Monitoring storage uses node-local volumes.
- Grafana is internally reachable through port forwarding only.
- Alert delivery is optional and needs runtime credentials.
- The dead-man's-switch is absent unless Healthchecks.io is configured.
- There is no database exporter; database health is inferred from Kubernetes
  StatefulSet state and the application readiness check.
