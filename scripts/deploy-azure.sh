#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nm2-homelab Azure deployment with Key Vault CSI + public ingress
#
# Provisions AKS + ACR + Key Vault + workload identity + NGINX ingress,
# builds and pushes images, exposes services via nip.io DNS with basic auth.
#
# Usage:
#   ./scripts/deploy-azure.sh              # full provision + build + deploy
#   ./scripts/deploy-azure.sh --skip-infra # skip Azure provisioning
#   ./scripts/deploy-azure.sh --skip-build # skip image build/push
#   ./scripts/deploy-azure.sh --teardown   # delete everything
#
# Estimated cost: ~€2-3/day (Standard_B2s node + Basic ACR + KV + LB)
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
RESOURCE_GROUP="rg-nm2-homelab"
LOCATION="uksouth"
ACR_NAME="nm2homelabacr"
AKS_NAME="aks-nm2-homelab"
AKS_NODE_SIZE="Standard_B2s"
AKS_NODE_COUNT=1
KV_NAME="kv-nm2-homelab"
IDENTITY_NAME="id-nm2-homelab"

# Passwords
PG_ADMIN_USER="postgres"
PG_ADMIN_PASSWORD="pg_admin_super"
PG_DATABASE="nm2"
INGEST_USER="nm2_ingest"
INGEST_PASSWORD="ingest_writer"
GRAFANA_DB_USER="nm2_grafana"
GRAFANA_DB_PASSWORD="grafana_reader"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="grafana_admin"

# Basic auth for ingress (protects ingest API and Prometheus)
BASIC_AUTH_USER="nm2"
BASIC_AUTH_PASSWORD="nm2_secure_api"

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
    echo "This will DELETE resource group ${RESOURCE_GROUP} and ALL resources in it."
    read -p "Are you sure? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        echo "==> Deleting resource group..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait
        echo "==> Purging Key Vault (soft-delete)..."
        az keyvault purge --name "$KV_NAME" --location "$LOCATION" 2>/dev/null || true
        echo "Deletion initiated. Check Azure portal for status."
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
    echo "==> Creating resource group..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none

    # Container Registry
    echo "==> Creating ACR..."
    az acr create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --sku Basic \
        --output none

    # Key Vault
    echo "==> Creating Key Vault..."
    az keyvault create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$KV_NAME" \
        --location "$LOCATION" \
        --enable-rbac-authorization true \
        --output none

    # AKS with OIDC, workload identity, Key Vault CSI addon
    echo "==> Creating AKS cluster (3-5 minutes)..."
    az aks create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_NAME" \
        --node-count "$AKS_NODE_COUNT" \
        --node-vm-size "$AKS_NODE_SIZE" \
        --attach-acr "$ACR_NAME" \
        --enable-oidc-issuer \
        --enable-workload-identity \
        --enable-addons azure-keyvault-secrets-provider \
        --generate-ssh-keys \
        --output none

    # User-assigned managed identity
    echo "==> Creating managed identity..."
    az identity create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --output none

    IDENTITY_CLIENT_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --query clientId -o tsv)
    IDENTITY_PRINCIPAL_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --query principalId -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)
    KV_ID=$(az keyvault show --name "$KV_NAME" --query id -o tsv)

    # Grant identity "Key Vault Secrets User"
    echo "==> Assigning Key Vault Secrets User role..."
    az role assignment create \
        --role "Key Vault Secrets User" \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "$KV_ID" \
        --output none

    # Grant current user "Key Vault Secrets Officer"
    CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
    echo "==> Granting current user secrets access..."
    az role assignment create \
        --role "Key Vault Secrets Officer" \
        --assignee-object-id "$CURRENT_USER_ID" \
        --assignee-principal-type User \
        --scope "$KV_ID" \
        --output none

    # RBAC propagation
    echo "==> Waiting for RBAC propagation (30s)..."
    sleep 30

    # Federated credential
    AKS_OIDC_ISSUER=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_NAME" \
        --query "oidcIssuerProfile.issuerUrl" -o tsv)

    echo "==> Creating federated credential..."
    az identity federated-credential create \
        --name "nm2-federated-cred" \
        --identity-name "$IDENTITY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --issuer "$AKS_OIDC_ISSUER" \
        --subject "system:serviceaccount:${NAMESPACE}:nm2-workload-identity" \
        --audiences "api://AzureADTokenExchange" \
        --output none

    # -----------------------------------------------------------------------
    # Populate Key Vault secrets
    # -----------------------------------------------------------------------
    echo "==> Storing secrets in Key Vault..."

    PG_HOST="nm2-postgres.${NAMESPACE}.svc"
    PG_PORT="5432"
    ADMIN_URI="postgresql://${PG_ADMIN_USER}:${PG_ADMIN_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}"
    INGEST_URI="postgresql://${INGEST_USER}:${INGEST_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}"
    GRAFANA_URI="postgresql://${GRAFANA_DB_USER}:${GRAFANA_DB_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}"

    kv_set() {
        az keyvault secret set --vault-name "$KV_NAME" --name "$1" --value "$2" --output none
    }

    kv_set "nm2-postgres-user"           "$PG_ADMIN_USER"
    kv_set "nm2-postgres-password"       "$PG_ADMIN_PASSWORD"
    kv_set "nm2-postgres-db"             "$PG_DATABASE"
    kv_set "nm2-postgres-admin-uri"      "$ADMIN_URI"
    kv_set "nm2-ingest-password"         "$INGEST_PASSWORD"
    kv_set "nm2-ingest-db-uri"           "$INGEST_URI"
    kv_set "nm2-grafana-password"        "$GRAFANA_DB_PASSWORD"
    kv_set "nm2-grafana-db-uri"          "$GRAFANA_URI"
    kv_set "nm2-grafana-admin-user"      "$GRAFANA_ADMIN_USER"
    kv_set "nm2-grafana-admin-password"  "$GRAFANA_ADMIN_PASSWORD"

    echo "==> Infrastructure provisioned."
    echo ""
else
    IDENTITY_CLIENT_ID=$(az identity show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IDENTITY_NAME" \
        --query clientId -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)
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
# Install NGINX Ingress Controller
# ---------------------------------------------------------------------------
echo "========================================"
echo " Installing NGINX Ingress Controller"
echo "========================================"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.replicaCount=1 \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"="/healthz" \
    --wait \
    --timeout 5m

# Wait for external IP
echo "==> Waiting for external IP (up to 3 minutes)..."
EXTERNAL_IP=""
for i in $(seq 1 36); do
    EXTERNAL_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 5
done

if [ -z "$EXTERNAL_IP" ]; then
    echo "ERROR: Could not get external IP after 3 minutes."
    echo "Check: kubectl -n ingress-nginx get svc"
    exit 1
fi

echo "==> External IP: ${EXTERNAL_IP}"

# ---------------------------------------------------------------------------
# Generate htpasswd for basic auth
# ---------------------------------------------------------------------------
echo "==> Generating htpasswd..."
# Use htpasswd if available, otherwise fall back to openssl
if command -v htpasswd &>/dev/null; then
    HTPASSWD_DATA=$(htpasswd -bn "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD")
else
    HTPASSWD_DATA="${BASIC_AUTH_USER}:$(openssl passwd -apr1 "$BASIC_AUTH_PASSWORD")"
fi

# nip.io hostnames — no DNS config needed, resolves automatically
INGEST_HOST="ingest.${EXTERNAL_IP}.nip.io"
GRAFANA_HOST="grafana.${EXTERNAL_IP}.nip.io"
PROMETHEUS_HOST="prometheus.${EXTERNAL_IP}.nip.io"

# ---------------------------------------------------------------------------
# Build & push images
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

keyvault:
  enabled: true
  name: "${KV_NAME}"
  tenantId: "${TENANT_ID}"
  clientId: "${IDENTITY_CLIENT_ID}"

# Values for Grafana datasource ConfigMap rendering.
# k8s Secrets come from Key Vault, not this block.
secrets:
  postgres:
    adminUser: "${PG_ADMIN_USER}"
    adminPassword: "${PG_ADMIN_PASSWORD}"
    database: "${PG_DATABASE}"
  ingest:
    user: "${INGEST_USER}"
    password: "${INGEST_PASSWORD}"
  grafana:
    dbUser: "${GRAFANA_DB_USER}"
    dbPassword: "${GRAFANA_DB_PASSWORD}"
    adminUser: "${GRAFANA_ADMIN_USER}"
    adminPassword: "${GRAFANA_ADMIN_PASSWORD}"

dbProvisioner:
  image: ${ACR_LOGIN_SERVER}/nm2-homelab/db-provisioner:latest

ingestApi:
  image: ${ACR_LOGIN_SERVER}/nm2-homelab/ingest-api:latest

postgres:
  storage:
    size: 1Gi
    storageClass: managed-csi

prometheus:
  remoteWriteReceiver: true
  storage:
    size: 1Gi
    storageClass: managed-csi

grafana:
  storage:
    size: 1Gi
    storageClass: managed-csi

ingress:
  enabled: true
  className: nginx
  basicAuth:
    enabled: true
    htpasswd: "${HTPASSWD_DATA}"
  ingestApi:
    host: "${INGEST_HOST}"
  grafana:
    host: "${GRAFANA_HOST}"
  prometheus:
    host: "${PROMETHEUS_HOST}"
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

kubectl -n "$NAMESPACE" get pods

echo ""
echo "Secrets:     Azure Key Vault (${KV_NAME})"
echo "External IP: ${EXTERNAL_IP}"
echo ""
echo "--- Public Endpoints ---"
echo ""
echo "Grafana:     http://${GRAFANA_HOST}"
echo "  Login:     ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD}"
echo ""
echo "Ingest API:  http://${INGEST_HOST}/healthz"
echo "  Auth:      ${BASIC_AUTH_USER} / ${BASIC_AUTH_PASSWORD}"
echo ""
echo "  Test:"
echo "  curl -u ${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} \\"
echo "    -X POST http://${INGEST_HOST}/v1/ingest/devices \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"records\": [{\"device_id\": \"lab-spine1\", \"hostname\": \"spine1.lab\", \"platform\": \"eos\"}]}'"
echo ""
echo "Prometheus:  http://${PROMETHEUS_HOST}"
echo "  Auth:      ${BASIC_AUTH_USER} / ${BASIC_AUTH_PASSWORD}"
echo ""
echo "  Remote write from home:"
echo "  remote_write:"
echo "    - url: http://${PROMETHEUS_HOST}/api/v1/write"
echo "      basic_auth:"
echo "        username: ${BASIC_AUTH_USER}"
echo "        password: ${BASIC_AUTH_PASSWORD}"
echo ""
echo "--- Teardown when done ---"
echo "  ./scripts/deploy-azure.sh --teardown"
