# Overview

This document covers the **ArgoCD Monitoring Stack** — a modular, automated installer that provisions a local Kubernetes environment with ArgoCD, Prometheus monitoring, Grafana dashboards, and Microsoft Teams alerting. The project follows GitOps principles: the setup script builds only the **platform infrastructure**, while all application definitions live in a separate Git repository managed by ArgoCD.

The stack is designed for KIND clusters running on WSL. It deploys `kube-prometheus-stack`, ArgoCD, and a Teams webhook proxy, then hands off application management entirely to ArgoCD via the **App of Apps** pattern.

## What does this project deploy?

The setup script automates the full platform provisioning lifecycle:

- A multi-node KIND cluster with pre-mapped NodePorts
- The `kube-prometheus-stack` Helm chart (Prometheus, Alertmanager, Grafana, Prometheus Operator)
- ArgoCD with metrics and ServiceMonitors enabled
- A Microsoft Teams alertmanager proxy (`prometheus-msteams`)
- A `PrometheusRule` resource with ArgoCD-specific alert definitions
- A Grafana dashboard loaded via ConfigMap and sidecar auto-import
- A single **root Application** that points to the `apps/` folder of your GitOps repository

The setup script **does not** define any workload applications. All applications (nginx, harbor, vault, etc.) are declared in the GitOps repository and discovered by ArgoCD automatically.

## Project structure

The project is split into two repositories:

### Setup repository (this repo)

```
argocd-monitoring-setup/
├── setup.sh                              # Main orchestrator script
├── kind-config.yaml                      # KIND cluster definition
├── helm-values/
│   ├── prometheus-values.yaml            # kube-prometheus-stack Helm values
│   └── argocd-values.yaml                # ArgoCD Helm values
├── manifests/
│   ├── alertmanager-msteams.yaml         # Teams webhook proxy deployment
│   ├── argocd-alerts.yaml                # PrometheusRule for ArgoCD alerts
│   ├── grafana-dashboard-cm.yaml         # Grafana dashboard as ConfigMap
│   └── root-app.yaml                     # The ONE root Application (App of Apps)
└── README.md
```

### GitOps repository (sample repo)

```
argocd-gitops/
├── apps/                                 # ArgoCD Application CRDs
│   ├── harbor.yaml
│   ├── nginx.yaml
│   └── vault.yaml
├── harbor/
│   └── values.yaml                       # Helm values for Harbor
├── nginx/
│   └── values.yaml                       # Helm values for Nginx
└── vault/
    └── values.yaml                       # Helm values for Vault
```

## Architecture

```
                        GitOps Repo - Github (sample)
                              │
                    ┌─────────┴──────────┐
                    │   apps/ folder      │
                    │  ┌──────────────┐   │
                    │  │ harbor.yaml  │   │
                    │  │ nginx.yaml   │   │
                    │  │ vault.yaml   │   │
                    │  └──────────────┘   │
                    └─────────┬──────────┘
                              │
                              │  clones & watches
                              ▼
                    ┌──────────────────┐
                    │  ArgoCD          │
                    │  (root-app)      │──── discovers & syncs child apps
                    └────────┬─────────┘
                             │
                             │  exposes /metrics
                             ▼
                    ┌──────────────────┐
                    │   Prometheus     │◄── scrapes via ServiceMonitors
                    │                  │    + additionalScrapeConfigs
                    └───────┬──┬───────┘
                            │  │
                  ┌─────────┘  └──────────┐
                  ▼                       ▼
         ┌──────────────┐       ┌──────────────────┐
         │   Grafana     │       │  Alertmanager     │
         │  (dashboard   │       │  (routes alerts)  │
         │   via sidecar)│       └────────┬─────────┘
         └──────────────┘                │
                                         ▼
                               ┌──────────────────┐
                               │ prometheus-msteams │
                               │  (webhook proxy)   │
                               └────────┬───────────┘
                                        │
                                        ▼
                               ┌──────────────────┐
                               │ Microsoft Teams   │
                               └──────────────────┘
```

---

# App of Apps pattern

This is the core design principle of the project. Instead of defining applications in the setup script, a single **root Application** is created that points to a folder in your GitOps repository. ArgoCD watches that folder and deploys every Application CRD it finds inside it.

## How it works

1. `setup.sh` creates one ArgoCD Application called `root-app`
2. `root-app` points to `apps/` in your GitOps repo
3. ArgoCD clones the repo, finds `apps/harbor.yaml`, `apps/nginx.yaml`, `apps/vault.yaml`
4. Each of those is an Application CRD — ArgoCD creates them as child applications
5. Each child app syncs its own source (Helm chart + values from the GitOps repo)
6. ArgoCD re-checks the repo every 3 minutes (default) for changes

## The root Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<user>/<repo>.git
    targetRevision: master
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The `GITOPS_REPO` placeholder in `manifests/root-app.yaml` is replaced at runtime by `setup.sh` using `sed`, based on the GitHub username and repo name you provide. The file on disk remains unchanged — the substituted output is piped directly to `kubectl apply`.

## Why this matters

- **The setup script never changes** when you add, remove, or modify applications
- **Git is the single source of truth** — every change is versioned, auditable, and reversible
- **Adding a new app** = commit two files to the GitOps repo. No `kubectl` needed.
- **Removing an app** = delete its files from Git. ArgoCD prunes it automatically.

---

# Prerequisites

Before running the script, the following tools must be installed and available on your `$PATH`:

| Tool | Purpose |
|---|---|
| `docker` | Container runtime required by KIND |
| `kubectl` | Kubernetes CLI for cluster interaction |
| `kind` | Creates local Kubernetes clusters using Docker containers as nodes |
| `helm` | Package manager for Kubernetes; installs the monitoring and ArgoCD charts |

The script will exit immediately if any of these are missing. You also need a **Microsoft Teams Incoming Webhook URL** and a **public GitHub repository** serving as your GitOps source.

> **Note on private repos**: If your GitOps repo is private, you must register it with ArgoCD by creating a Kubernetes Secret with your credentials before the root app can sync. See the [Private repository access](#private-repository-access) section.

---

# Configuration

## User inputs

The script prompts for three values at startup:

| Input | Description |
|---|---|
| GitHub username | Owner of the GitOps repository |
| GitOps repo name | Repository containing `apps/` folder and values files |
| Teams webhook URL | Microsoft Teams Incoming Webhook URL for alert notifications |

## KIND cluster

The cluster is named `argocd-monitoring` and consists of one control-plane node and two worker nodes. Four host ports are mapped to NodePorts inside the cluster:

| Host port | Service |
|---|---|
| `30080` | ArgoCD UI |
| `30090` | Prometheus |
| `30030` | Grafana |
| `30093` | Alertmanager |

If a cluster with the same name already exists, the script deletes it before recreating.

## Placeholder substitution

Two manifest files contain placeholders that are replaced at runtime using `sed`:

| File | Placeholder | Replaced with |
|---|---|---|
| `manifests/root-app.yaml` | `GITOPS_REPO` | `https://github.com/<user>/<repo>.git` |
| `manifests/alertmanager-msteams.yaml` | `TEAMS_WEBHOOK_URL` | The Teams webhook URL you provide |

The `sed` output is piped directly to `kubectl apply` — the original files on disk are never modified.

---

# Components

## kube-prometheus-stack

The [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm chart is the backbone of the monitoring layer. It deploys Prometheus, Alertmanager, Grafana, and the Prometheus Operator in one shot.

The Prometheus Operator introduces Kubernetes Custom Resource Definitions (CRDs) that let you manage monitoring configuration as native Kubernetes objects rather than hand-editing config files. The two most relevant CRDs in this stack are:

- **ServiceMonitor**: Tells Prometheus which Kubernetes Services to scrape and how. The ArgoCD Helm chart creates ServiceMonitors for the controller, server, repo-server, applicationSet, and notifications components. Each is labelled `release: kube-prometheus-stack` so that the Prometheus Operator picks them up.

- **PrometheusRule**: Defines alerting (and recording) rules as Kubernetes resources. The setup applies a `PrometheusRule` named `argocd-alerts` containing six alert definitions. Prometheus loads these rules automatically through the Operator.

### Scrape configuration

ArgoCD metrics are ingested through two mechanisms simultaneously:

1. **ServiceMonitors** created by the ArgoCD Helm chart (one per component). These are the recommended, dynamic approach.
2. **`additionalScrapeConfigs`** in the Prometheus Helm values, which define static targets pointing at the ArgoCD service DNS names. These act as a fallback and ensure scraping works even if ServiceMonitor discovery has issues.

The Helm values set `serviceMonitorSelectorNilUsesHelmValues: false` and empty selectors for both ServiceMonitors and PodMonitors — this tells Prometheus to discover **all** ServiceMonitor and PodMonitor resources across **all** namespaces, not just those created by the Helm release.

## Alertmanager

Alertmanager receives firing alerts from Prometheus, groups them by `alertname` and `namespace`, and dispatches notifications to the configured receiver.

### Routing

```yaml
route:
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'msteams'
  routes:
    - match:
        severity: critical
      receiver: 'msteams'
      continue: true
    - match:
        severity: warning
      receiver: 'msteams'
```

All alerts go to the `msteams` receiver. `group_wait: 30s` means Alertmanager waits 30 seconds after the first alert in a group before sending, allowing related alerts to be batched. `group_interval: 5m` controls the minimum time between notifications for the same group. `repeat_interval: 12h` prevents spam — the same alert only re-fires every 12 hours.

The `continue: true` on the critical route means that after matching a critical alert, Alertmanager continues evaluating subsequent routes (useful if you later add separate receivers for different severities).

### Microsoft Teams proxy

Alertmanager does not natively support Microsoft Teams. The stack deploys [`prometheus-msteams`](https://github.com/bzon/prometheus-msteams) as a translation layer. It runs as a Deployment in the `monitoring` namespace, accepts Alertmanager webhook payloads on port `2000` at the `/alertmanager` path, and converts them into Teams MessageCard format before posting to the configured Incoming Webhook URL.

## ArgoCD

ArgoCD is deployed via the `argo/argo-cd` Helm chart (version `9.4.10`, corresponding to ArgoCD `v3.3.3`). The server runs in insecure mode (`server.insecure: true`) since this is a local development cluster exposed via NodePort, not through an ingress with TLS.

### Metrics endpoints

Each ArgoCD component exposes Prometheus metrics on a dedicated port:

| Component | Port | Metrics path |
|---|---|---|
| Application Controller | `8082` | `/metrics` |
| API Server | `8083` | `/metrics` |
| Repo Server | `8084` | `/metrics` |

Key metrics exposed include `argocd_app_info` (labels: `name`, `namespace`, `dest_namespace`, `health_status`, `sync_status`), `argocd_app_sync_total`, and standard Go runtime/process metrics.

---

# Alerting rules

The `PrometheusRule` resource `argocd-alerts` defines six rules in the group `argocd.application.status`:

### ArgoCDAppOutOfSync

```
expr: argocd_app_info{sync_status!="Synced"} == 1
for:  5m
severity: warning
```

Fires when any ArgoCD application has a sync status other than `Synced` for more than 5 minutes. This typically means a Git commit has not been applied to the cluster, or sync was intentionally paused.

### ArgoCDAppUnhealthy

```
expr: argocd_app_info{health_status!="Healthy"} == 1
for:  5m
severity: critical
```

Fires when an application's health status is anything other than `Healthy` (e.g., `Degraded`, `Progressing`, `Missing`, `Suspended`) for 5 minutes. This is critical because it usually indicates broken workloads.

### ArgoCDAppSyncFailed

```
expr: argocd_app_info{sync_status="Unknown"} == 1
for:  2m
severity: critical
```

Fires when sync status is `Unknown` for 2 minutes. This often indicates that the sync operation itself has failed or that ArgoCD cannot reach the Git repository.

### ArgoCDAppMissing

```
expr: absent(argocd_app_info)
for:  5m
severity: warning
```

Uses the `absent()` function to detect the complete disappearance of the `argocd_app_info` metric. If no ArgoCD application metrics exist for 5 minutes, ArgoCD itself may be down.

### ArgoCDHighSyncRate

```
expr: increase(argocd_app_sync_total[10m]) > 10
for:  0m
severity: warning
```

Fires immediately if an application syncs more than 10 times in a 10-minute window. This can indicate a sync loop — where ArgoCD keeps syncing because the desired state and live state never converge (often caused by mutating webhooks, operator-managed fields, or `selfHeal` fighting with a controller).

### ArgoCDControllerDown

```
expr: absent(up{job="argocd-metrics"} == 1)
for:  5m
severity: critical
```

Fires when the `argocd-metrics` scrape job is not returning `up == 1`. This means Prometheus cannot reach the application controller's metrics endpoint — the controller may have crashed or the service is gone.

---

# Grafana dashboard

The dashboard is loaded via a **Kubernetes ConfigMap** with the label `grafana_dashboard: "1"`. Grafana's sidecar container (enabled in the Prometheus Helm values) watches for ConfigMaps with this label and automatically imports them as dashboards. This eliminates the need for `curl`-based API imports or waiting for Grafana readiness.

The ConfigMap is defined in `manifests/grafana-dashboard-cm.yaml` and applied with a simple `kubectl apply`.

### How the sidecar works

1. The `kube-prometheus-stack` Helm values enable `sidecar.dashboards.enabled: true` and set `sidecar.dashboards.label: grafana_dashboard`
2. The sidecar container runs alongside Grafana and watches all ConfigMaps across namespaces
3. When it finds a ConfigMap with the label `grafana_dashboard: "1"`, it reads the JSON from the `data` field and writes it to Grafana's provisioning directory
4. Grafana picks up the new file and loads the dashboard — no API calls, no credentials needed

### Panels

The dashboard auto-refreshes every 30 seconds and includes a template variable `$app` that queries `label_values(argocd_app_info, name)`.

The top row contains six **stat panels** showing aggregate counts:

| Panel | Query |
|---|---|
| Total | `count(argocd_app_info)` |
| Healthy + Synced | `count(argocd_app_info{health_status="Healthy", sync_status="Synced"})` |
| Healthy + OutOfSync | `count(argocd_app_info{health_status="Healthy", sync_status!="Synced"})` |
| Degraded | `count(argocd_app_info{health_status="Degraded"})` |
| Progressing | `count(argocd_app_info{health_status="Progressing"})` |
| Missing | `count(argocd_app_info{health_status="Missing"})` |

Below the summary row, a **repeating stat panel** generates one tile per application (using the `$app` variable with `repeat`). Each tile is color-coded based on the combination of `health_status` and `sync_status`:

| State | Color |
|---|---|
| Healthy + Synced | Green (`#1a9c4e`) |
| Healthy + OutOfSync | Orange (`#f57c00`) |
| Degraded + Synced | Dark Red (`#7f0000`) |
| Degraded + OutOfSync | Red (`#d32f2f`) |
| Progressing + Synced | Lime (`#c6ff00`) |
| Progressing + OutOfSync | Amber (`#f9a825`) |
| Missing + OutOfSync | Purple (`#6a1b9a`) |
| Unknown + Unknown | Grey (`#616161`) |

---

# Setup execution flow

The script runs through these steps in order:

| Step | Action | Files used |
|---|---|---|
| 0 | Prompt for GitHub user, repo name, Teams webhook URL | — |
| 1 | Check that `docker`, `kubectl`, `kind`, `helm` are installed | — |
| 2 | Create KIND cluster (delete existing if present) | `kind-config.yaml` |
| 3 | Add and update Helm repositories | — |
| 4 | Deploy `kube-prometheus-stack` into `monitoring` namespace | `helm-values/prometheus-values.yaml` |
| 5 | Deploy Teams webhook proxy (with `sed` substitution) | `manifests/alertmanager-msteams.yaml` |
| 6 | Deploy ArgoCD into `argocd` namespace | `helm-values/argocd-values.yaml` |
| 7 | Apply PrometheusRule and Grafana dashboard ConfigMap | `manifests/argocd-alerts.yaml`, `manifests/grafana-dashboard-cm.yaml` |
| 8 | Apply root Application (with `sed` substitution) | `manifests/root-app.yaml` |
| 9 | Print access credentials and URLs | — |

After Step 8, ArgoCD takes over: it syncs the root app, discovers child applications in `apps/`, and deploys them. No further script involvement is needed.

---

# Adding a new application

To extend the stack with a new ArgoCD-managed application:

1. Create the manifests or Helm values in your GitOps repo under a new directory (e.g., `hello-world/manifest.yaml`)
2. Add an Application CRD to the `apps/` folder (e.g., `apps/hello-world.yaml`) pointing to that directory
3. Commit and push to Git

ArgoCD detects the new file in `apps/`, creates the child application, and syncs it. The application tile appears automatically in the Grafana dashboard on the next refresh cycle, since the `$app` template variable dynamically queries all `argocd_app_info` label values.

**No changes to the setup script, Prometheus configuration, or Grafana dashboard are needed.**

### Example: adding a hello-world app

**`apps/hello-world.yaml`**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-world
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: gitops-apps
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<user>/<repo>.git
    targetRevision: master
    path: hello-world
  destination:
    server: https://kubernetes.default.svc
    namespace: hello-world
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**`hello-world/manifest.yaml`**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
spec:
  selector:
    app: hello-world
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

Commit both files, push, and watch the tile appear in Grafana within a few minutes.

# Removing an application

Delete the Application CRD from `apps/` and optionally its manifests directory, then commit and push. Because the root app has `prune: true` and the child apps have the `resources-finalizer.argocd.argoproj.io` finalizer, ArgoCD will:

1. Detect that the Application CRD was removed from Git
2. Delete the Application resource from the cluster
3. The finalizer triggers deletion of all resources the app managed (pods, services, namespaces if created by ArgoCD)

---

# Private repository access

If your GitOps repository is private, ArgoCD needs credentials to clone it. Create a Kubernetes Secret before the root app is applied:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/<user>/<repo>.git
  username: <github-username>
  password: <github-personal-access-token>
```

Apply it with `kubectl apply -f` before Step 8 of the setup script. The personal access token needs `repo` scope for private repositories.

---

# Troubleshooting

## KIND cluster fails to create

**Symptom**: `kind create cluster` exits with errors about port binding or Docker.

This almost always means Docker is not running, or another process is already bound to one of the host ports (30080, 30090, 30030, 30093). Check with `ss -tlnp | grep 300` or `netstat -tlnp | grep 300` and kill the conflicting process. On WSL, also make sure the Docker Desktop WSL integration is enabled.

## Helm install times out

**Symptom**: `helm install` hangs and eventually fails with a timeout.

The `--wait --timeout 5m` flag means Helm waits for all pods to reach `Ready`. If the cluster nodes don't have enough resources, pods will stay in `Pending`. Check with `kubectl get pods -A` and `kubectl describe pod <name> -n <namespace>`. On KIND, ensure Docker has at least 4 GB of memory allocated.

## Prometheus shows no ArgoCD targets

**Symptom**: ArgoCD metrics are missing in Prometheus; targets page shows `0/0 up` for ArgoCD jobs.

Check two things. First, verify the ServiceMonitors exist: `kubectl get servicemonitor -n monitoring`. They should include entries for `argocd-server`, `argocd-application-controller`, and `argocd-repo-server`. If they are missing, the ArgoCD Helm values may not have `metrics.enabled: true` or the `additionalLabels.release` does not match. Second, check the static scrape configs by querying the Prometheus config: `curl localhost:30090/api/v1/status/config | jq` and search for `argocd-metrics`.

## Alerts not reaching Microsoft Teams

**Symptom**: Alerts fire in Prometheus but no messages appear in Teams.

Walk the pipeline backwards:

1. **Check the `prometheus-msteams` proxy**: `kubectl logs -n monitoring deployment/alertmanager-msteams`. Look for HTTP errors or connection timeouts.
2. **Verify the webhook URL**: Teams webhooks expire or get disabled if the channel/connector is removed. Test manually: `curl -X POST -H "Content-Type: application/json" -d '{"text":"test"}' "<your-webhook-url>"`.
3. **Check Alertmanager routing**: Visit `http://localhost:30093/#/status` and verify the config shows the `msteams` receiver.
4. **DNS resolution**: If the `prometheus-msteams` service was created after Alertmanager, restart the Alertmanager pod: `kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring`.

## Grafana dashboard shows "No data"

**Symptom**: The ArgoCD tiles dashboard loads but all panels say "No data".

The dashboard queries `argocd_app_info`, which is only emitted once ArgoCD applications exist **and** Prometheus is scraping the controller. Check that at least one Application is synced (`kubectl get applications -n argocd`) and that Prometheus has the metric: `curl 'http://localhost:30090/api/v1/query?query=argocd_app_info'`. If the metric exists but Grafana still shows nothing, verify the Prometheus datasource under Grafana → Configuration → Data Sources.

## Grafana dashboard not appearing

**Symptom**: The dashboard ConfigMap was applied but the dashboard doesn't show in Grafana.

Verify the ConfigMap exists with the correct label: `kubectl get configmap argocd-tiles-dashboard -n monitoring --show-labels`. The label `grafana_dashboard=1` must be present. If it is, check the Grafana sidecar logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard`. The sidecar should log that it found and loaded the ConfigMap.

## Applications stuck in "Progressing"

**Symptom**: ArgoCD applications show `Progressing` indefinitely.

Harbor and Vault are resource-heavy. On a KIND cluster with limited resources, their pods may not schedule. Check `kubectl get pods -n <namespace>` for `Pending` pods, then `kubectl describe pod` to see if it is waiting on CPU, memory, or PersistentVolumeClaims. For local testing, ensure your GitOps values files disable persistence or use `emptyDir`.

## Multi-source application sync fails

**Symptom**: Applications show sync status `Unknown` or `Failed` with errors referencing `$values`.

This happens when ArgoCD cannot clone your GitOps repository. Verify the repo is public (or that credentials are configured). Check ArgoCD repo-server logs: `kubectl logs -n argocd deployment/argocd-repo-server`. Also confirm the repo contains the expected paths on the correct branch. If your default branch is `main` but the Application CRDs reference `master`, update `targetRevision` accordingly.

## Alertmanager PVC stuck in Pending

**Symptom**: Alertmanager pod stays in `Pending` because the PersistentVolumeClaim cannot be bound.

KIND clusters need a default StorageClass. KIND ships with `rancher.io/local-path` as the default provisioner. Verify with `kubectl get storageclass`. If no default exists, either install the local-path-provisioner or remove the `storage` block from the Alertmanager Helm values.

---

# Access summary

After a successful run, the script prints credentials and endpoints:

| Service | URL | Credentials |
|---|---|---|
| ArgoCD UI | `http://localhost:30080` | `admin` / *(auto-generated, printed at end)* |
| Prometheus | `http://localhost:30090` | — |
| Grafana | `http://localhost:30030` | `admin` / `admin123` |
| Alertmanager | `http://localhost:30093` | — |
| Dashboard | `http://localhost:30030/d/argocd-tiles-v7` | Same as Grafana |

The ArgoCD admin password is extracted from the `argocd-initial-admin-secret` Kubernetes Secret. Change it after first login with `argocd account update-password`.
