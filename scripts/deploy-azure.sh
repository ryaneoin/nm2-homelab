#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nm2-homelab Azure deployment
#
# Provisions a minimal AKS cluster + ACR, builds and pushes images,
# then deploys the Helm chart. Designed to be cheap and teardown-friendly.
#
# Usage:
#   ./scripts/deploy-azure.sh              # full provision + build + deploy
#   ./scripts/deploy-azure.sh --skip-infra # skip AKS/ACR (already provisioned)
#   ./scripts/deploy-azure.sh --skip-build # skip image build (already pushed)
#   ./scripts/deploy-azure.sh --teardown   # delete everything
#
# Estimated cost: ~€1-2/day (Standard_B2s single node + Basic ACR)
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
RESOURCE_GROUP="rg-nm2-homelab"
LOCATION="uksouth"
ACR_NAME="nm2homelabacr"          # must be globally unique, lowercase, no hyphens
AKS_NAME="aks-nm2-homelab"
AKS_NODE_SIZE="Standard_B2s"      # 2 vCPU, 4 GB RAM — cheapest viable option
AKS_NODE_COUNT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_ROOT/images"
CHART_DIR="$PROJECT_ROOT/helm/nm2-homelab"
VALUES_FILE="$CHART_DIR/values.yaml"
VALUES_AZURE="$CHART_DIR/values-azure.yaml"

RELEASE_NAME="nm2-homelab"
NAMESPACE="nm2-homelab"
TARGET_PLATFORM="linux/amd64"

SKIP_INFRA=false
SKIP_BUILD=false
TEARDOWN=false

for arg in "$@"; do
    case $arg in
        --skip-infra) SKIP_INFRA=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --teardown)   TEARDOWN=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
if [ "$TEARDOWN" = true ]; then
    echo "========================================"
    echo " Tearing down Azure resources"
    echo "========================================"
    echo "This will DELETE the resource group ${RESOURCE_GROUP} and ALL resources in it."
    read -p "Are you sure? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait
        echo "Deletion initiated (runs in background). Check Azure portal for status."
    else
        echo "Cancelled."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Provision infrastructure
# ---------------------------------------------------------------------------
if [ "$SKIP_INFRA" = false ]; then
    echo "========================================"
    echo " Provisioning Azure infrastructure"
    echo "========================================"

    # Resource group
    echo "==> Creating resource group ${RESOURCE_GROUP} in ${LOCATION}..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none

    # Container Registry (Basic tier — cheapest)
    echo "==> Creating ACR ${ACR_NAME}..."
    az acr create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --sku Basic \
        --output none

    # AKS cluster (single node, attached to ACR)
    echo "==> Creating AKS cluster ${AKS_NAME} (this takes 3-5 minutes)..."
    az aks create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_NAME" \
        --node-count "$AKS_NODE_COUNT" \
        --node-vm-size "$AKS_NODE_SIZE" \
        --attach-acr "$ACR_NAME" \
        --generate-ssh-keys \
        --output none

    echo "==> Infrastructure provisioned."
    echo ""
fi

# ---------------------------------------------------------------------------
# Get credentials
# ---------------------------------------------------------------------------
echo "==> Fetching AKS credentials..."
az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --overwrite-existing

echo "==> Logging into ACR..."
az acr login --name "$ACR_NAME"

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
echo "==> ACR login server: ${ACR_LOGIN_SERVER}"

# ---------------------------------------------------------------------------
# Build & push images to ACR
# ---------------------------------------------------------------------------
build_and_push() {
    local name=$1
    local dir=$2
    local tag="${ACR_LOGIN_SERVER}/nm2-homelab/${name}:latest"

    echo "==> Building ${tag} (${TARGET_PLATFORM})..."
    docker build --platform "$TARGET_PLATFORM" -t "$tag" "$dir"

    echo "==> Pushing ${tag}..."
    docker push "$tag"

    echo "==> ${tag} pushed."
}

if [ "$SKIP_BUILD" = false ]; then
    echo "========================================"
    echo " Building and pushing container images"
    echo "========================================"
    build_and_push "db-provisioner" "$IMAGES_DIR/db-provisioner"
    build_and_push "ingest-api"     "$IMAGES_DIR/ingest-api"
    echo ""
fi

# ---------------------------------------------------------------------------
# Generate values-azure.yaml
# ---------------------------------------------------------------------------
echo "==> Generating ${VALUES_AZURE}..."
cat > "$VALUES_AZURE" <<VALUESEOF
# Auto-generated by deploy-azure.sh — do not commit
secrets:
  postgres:
    adminPassword: "pg_admin_super"
  ingest:
    password: "ingest_writer"
  grafana:
    dbPassword: "grafana_reader"
    adminPassword: "grafana_admin"

dbProvisioner:
  image: ${ACR_LOGIN_SERVER}/nm2-homelab/db-provisioner:latest

ingestApi:
  image: ${ACR_LOGIN_SERVER}/nm2-homelab/ingest-api:latest

postgres:
  storage:
    size: 1Gi
    storageClass: managed-csi

prometheus:
  storage:
    size: 1Gi
    storageClass: managed-csi

grafana:
  storage:
    size: 1Gi
    storageClass: managed-csi

ingress:
  enabled: false
VALUESEOF

# ---------------------------------------------------------------------------
# Helm deploy
# ---------------------------------------------------------------------------
echo "========================================"
echo " Deploying with Helm"
echo "========================================"
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    -f "$VALUES_FILE" \
    -f "$VALUES_AZURE" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 5m

echo ""
echo "========================================"
echo " Deployment complete"
echo "========================================"
echo ""

# Show pod status
kubectl -n "$NAMESPACE" get pods

echo ""
echo "--- Access via port-forward ---"
echo ""
echo "Grafana:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/nm2-grafana 3000:3000"
echo "  open http://localhost:3000  (admin / grafana_admin)"
echo ""
echo "Ingest API:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/nm2-ingest 8080:8080"
echo "  curl http://localhost:8080/healthz"
echo ""
echo "Prometheus:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/nm2-prometheus 9090:9090"
echo "  open http://localhost:9090"
echo ""
echo "--- Teardown when done ---"
echo "  ./scripts/deploy-azure.sh --teardown"
echo "  (~€1-2/day while running)"
