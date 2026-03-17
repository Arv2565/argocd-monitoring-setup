#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
#  ArgoCD Monitoring Stack — Setup Script
#  KIND + WSL | kube-prometheus + ArgoCD
#  Alerts → Microsoft Teams (optional)
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

# Get the directory where this script lives (so file paths work from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║     ArgoCD Monitoring Stack Setup Script     ║"
echo "║     KIND + kube-prometheus + Teams Alerts    ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ─────────────────────────────────────────────
# STEP 0 — User Inputs
# ─────────────────────────────────────────────
echo -e "${YELLOW}── Configuration ─────────────────────────────${NC}"
read -rp "  GitHub username            : " GITHUB_USER
read -rp "  GitOps repo name           : " GITHUB_REPO
echo ""
read -rp "  Teams Incoming Webhook URL (press Enter to skip) : " TEAMS_WEBHOOK_URL
echo ""

[[ -n "$GITHUB_USER" ]] || error "GitHub username cannot be empty"
[[ -n "$GITHUB_REPO" ]] || error "GitHub repo name cannot be empty"

GITOPS_REPO="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
CLUSTER_NAME="argocd-monitoring"

if [[ -n "$TEAMS_WEBHOOK_URL" ]]; then
  TEAMS_ENABLED=true
  info "Teams alerting: ENABLED"
else
  TEAMS_ENABLED=false
  warn "Teams alerting: SKIPPED (no webhook URL provided)"
fi

# ─────────────────────────────────────────────
# STEP 1 — Prerequisite Checks
# ─────────────────────────────────────────────
info "Checking prerequisites..."

for cmd in docker kubectl kind helm; do
  command -v "$cmd" &>/dev/null || error "'$cmd' not found. Please install it first."
  success "$cmd found"
done

# ─────────────────────────────────────────────
# STEP 2 — KIND Cluster
# ─────────────────────────────────────────────
info "Setting up KIND cluster: $CLUSTER_NAME"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '$CLUSTER_NAME' already exists — deleting it..."
  kind delete cluster --name "$CLUSTER_NAME"
fi

kind create cluster --name "$CLUSTER_NAME" --config "${SCRIPT_DIR}/kind-config.yaml"
kubectl config use-context "kind-${CLUSTER_NAME}"
success "KIND cluster created"

info "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
success "All nodes ready"

# ─────────────────────────────────────────────
# STEP 3 — Helm Repos
# ─────────────────────────────────────────────
info "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
success "Helm repos updated"

# ─────────────────────────────────────────────
# STEP 4 — kube-prometheus-stack
# ─────────────────────────────────────────────
info "Deploying kube-prometheus-stack..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

HELM_EXTRA_ARGS=""
if [[ "$TEAMS_ENABLED" == false ]]; then
  # Override the receiver to a null sink so Alertmanager doesn't try to reach the Teams proxy
  HELM_EXTRA_ARGS="--set alertmanager.config.route.receiver=null"
  HELM_EXTRA_ARGS="$HELM_EXTRA_ARGS --set alertmanager.config.route.routes=null"
  HELM_EXTRA_ARGS="$HELM_EXTRA_ARGS --set alertmanager.config.receivers[0].name=null"
fi

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values "${SCRIPT_DIR}/helm-values/prometheus-values.yaml" \
  $HELM_EXTRA_ARGS \
  --wait --timeout 5m

success "kube-prometheus-stack deployed"

# ─────────────────────────────────────────────
# STEP 5 — Teams Alertmanager Proxy (optional)
# ─────────────────────────────────────────────
if [[ "$TEAMS_ENABLED" == true ]]; then
  info "Deploying Microsoft Teams alert proxy..."

  sed "s|TEAMS_WEBHOOK_URL|${TEAMS_WEBHOOK_URL}|g" \
    "${SCRIPT_DIR}/manifests/alertmanager-msteams.yaml" | kubectl apply -f -

  kubectl rollout status deployment/alertmanager-msteams -n monitoring --timeout=120s
  success "Teams proxy deployed"
else
  warn "Skipping Teams proxy deployment"
fi

# ─────────────────────────────────────────────
# STEP 6 — ArgoCD
# ─────────────────────────────────────────────
info "Deploying ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm install argocd argo/argo-cd \
  --version 9.4.10 \
  --namespace argocd \
  --values "${SCRIPT_DIR}/helm-values/argocd-values.yaml" \
  --wait --timeout 5m

success "ArgoCD deployed"

# ─────────────────────────────────────────────
# STEP 7 — Alert Rules + Grafana Dashboard
# ─────────────────────────────────────────────
info "Applying PrometheusRule alert rules..."
kubectl apply -f "${SCRIPT_DIR}/manifests/argocd-alerts.yaml"
success "Alert rules applied"

info "Applying Grafana dashboard ConfigMap..."
kubectl apply -f "${SCRIPT_DIR}/manifests/grafana-dashboard-cm.yaml"
success "Dashboard ConfigMap applied (Grafana sidecar will auto-import it)"

# ─────────────────────────────────────────────
# STEP 8 — Root Application (App of Apps)
# ─────────────────────────────────────────────
info "Deploying root application → ${GITOPS_REPO}"

sed "s|GITOPS_REPO|${GITOPS_REPO}|g" \
  "${SCRIPT_DIR}/manifests/root-app.yaml" | kubectl apply -f -

success "Root application deployed — ArgoCD will now sync apps from your GitOps repo"

# ─────────────────────────────────────────────
# STEP 9 — Summary
# ─────────────────────────────────────────────
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Setup Complete!                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}ArgoCD UI${NC}      →  http://localhost:30080"
echo -e "                    user: admin"
echo -e "                    pass: ${ARGOCD_PASSWORD}"
echo ""
echo -e "  ${CYAN}Prometheus${NC}     →  http://localhost:30090"
echo -e "  ${CYAN}Grafana${NC}        →  http://localhost:30030"
echo -e "                    user: admin  |  pass: admin123"
echo -e "  ${CYAN}Alertmanager${NC}   →  http://localhost:30093"
echo ""
echo -e "  ${CYAN}Dashboard${NC}      →  http://localhost:30030/d/argocd-tiles-v7"
echo ""
echo -e "  ${YELLOW}GitOps repo${NC}    →  ${GITOPS_REPO}"
if [[ "$TEAMS_ENABLED" == true ]]; then
  echo -e "  ${YELLOW}Teams alerts${NC}   →  Enabled"
else
  echo -e "  ${YELLOW}Teams alerts${NC}   →  Disabled (no webhook URL provided)"
fi
echo ""
echo -e "  ${CYAN}To add a new app:${NC}"
echo -e "  1. Add values/manifests to your gitops repo"
echo -e "  2. Add an Application CRD to the apps/ folder"
echo -e "  3. Commit & push — ArgoCD picks it up automatically"
echo ""
