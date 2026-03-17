#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nm2-homelab Azure deployment with Key Vault CSI
#
# Provisions AKS + ACR + Key Vault + workload identity, builds and pushes
# images, then deploys the Helm chart with secrets sourced from Key Vault.
#
# Usage:
#   ./scripts/deploy-azure.sh              # full provision + build + deploy
#   ./scripts/deploy-azure.sh --skip-infra # skip Azure provisioning
#   ./scripts/deploy-azure.sh --skip-build # skip image build/push
#   ./scripts/deploy-azure.sh --teardown   # delete everything
#
# Estimated cost: ~€2-3/day (Standard_B2s node + Basic ACR + KV standard)
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

# Passwords for the demo
PG_ADMIN_USER="postgres"
PG_ADMIN_PASSWORD="pg_admin_super"
PG_DATABASE="nm2"
INGEST_USER="nm2_ingest"
INGEST_PASSWORD="ingest_writer"
GRAFANA_DB_USER="nm2_grafana"
GRAFANA_DB_PASSWORD="grafana_reader"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="grafana_admin"

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
        # Key Vault has soft-delete; purge to avoid name conflicts on redeploy
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

    # Container Registry (Basic tier)
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

    # Grant identity "Key Vault Secrets User" on the KV
    echo "==> Assigning Key Vault Secrets User role..."
    az role assignment create \
        --role "Key Vault Secrets User" \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "$KV_ID" \
        --output none

    # Grant current user "Key Vault Secrets Officer" to populate secrets
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

    # Federated credential: k8s ServiceAccount → managed identity
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
# Note: secrets{} block is still needed even with KV enabled — the Grafana
# datasource ConfigMap template references these values for rendering.
# The k8s Secrets themselves come from Key Vault, not from this block.
# ---------------------------------------------------------------------------
echo "==> Generating ${VALUES_AZURE}..."
cat > "$VALUES_AZURE" <<VALUESEOF
# Auto-generated by deploy-azure.sh — do not commit

keyvault:
  enabled: true
  name: "${KV_NAME}"
  tenantId: "${TENANT_ID}"
  clientId: "${IDENTITY_CLIENT_ID}"

# These values are used ONLY for Grafana datasource ConfigMap rendering.
# The actual k8s Secrets are synced from Key Vault via SecretProviderClass.
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

kubectl -n "$NAMESPACE" get pods

echo ""
echo "Secrets sourced from Azure Key Vault: ${KV_NAME}"
echo ""
echo "--- Access via port-forward ---"
echo ""
echo "Grafana:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/nm2-grafana 3000:3000"
echo "  open http://localhost:3000  (${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD})"
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
