#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# nm2-homelab deploy script
#
# Builds container images locally, imports them into k3s containerd,
# and deploys via Helm.
#
# Usage:
#   ./scripts/deploy.sh                    # full build + deploy
#   ./scripts/deploy.sh --skip-build       # helm only (images already loaded)
#   ./scripts/deploy.sh --template-only    # render templates, don't deploy
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_ROOT/images"
CHART_DIR="$PROJECT_ROOT/helm/nm2-homelab"
VALUES_FILE="$CHART_DIR/values.yaml"
VALUES_LOCAL="$CHART_DIR/values-local.yaml"

RELEASE_NAME="nm2-homelab"
NAMESPACE="nm2-homelab"

# Target platform — charlie is amd64, Mac builds arm64 by default
TARGET_PLATFORM="linux/amd64"

# k3s node(s) to load images onto — adjust as needed
K3S_NODE="charlie"

SKIP_BUILD=false
TEMPLATE_ONLY=false

for arg in "$@"; do
    case $arg in
        --skip-build)    SKIP_BUILD=true ;;
        --template-only) TEMPLATE_ONLY=true ;;
    esac
done

# Build values file args — layer local overrides if present
HELM_VALUES=(-f "$VALUES_FILE")
if [ -f "$VALUES_LOCAL" ]; then
    echo "[info] Found values-local.yaml — layering local overrides"
    HELM_VALUES+=(-f "$VALUES_LOCAL")
fi

# ---------------------------------------------------------------------------
# Build & load images
# ---------------------------------------------------------------------------
build_and_load() {
    local name=$1
    local dir=$2
    local tag="nm2-homelab/${name}:latest"

    echo "==> Building ${tag} (${TARGET_PLATFORM})..."
    docker build --platform "$TARGET_PLATFORM" -t "$tag" "$dir"

    echo "==> Exporting ${tag} to tarball..."
    docker save "$tag" -o "/tmp/${name}.tar"

    echo "==> Loading ${tag} into k3s on ${K3S_NODE}..."
    # If running this script FROM the k3s node:
    if command -v k3s &>/dev/null; then
        sudo k3s ctr images import "/tmp/${name}.tar"
    else
        # Remote: scp then import
        scp "/tmp/${name}.tar" "${K3S_NODE}:/tmp/${name}.tar"
        ssh "$K3S_NODE" "sudo k3s ctr images import /tmp/${name}.tar && rm /tmp/${name}.tar"
    fi

    rm -f "/tmp/${name}.tar"
    echo "==> ${tag} loaded."
}

if [ "$SKIP_BUILD" = false ] && [ "$TEMPLATE_ONLY" = false ]; then
    echo "========================================"
    echo " Building container images"
    echo "========================================"
    build_and_load "db-provisioner" "$IMAGES_DIR/db-provisioner"
    build_and_load "ingest-api"     "$IMAGES_DIR/ingest-api"
    echo ""
fi

# ---------------------------------------------------------------------------
# Helm deploy
# ---------------------------------------------------------------------------
if [ "$TEMPLATE_ONLY" = true ]; then
    echo "========================================"
    echo " Rendering templates (dry-run)"
    echo "========================================"
    helm template "$RELEASE_NAME" "$CHART_DIR" \
        "${HELM_VALUES[@]}" \
        --namespace "$NAMESPACE"
    exit 0
fi

echo "========================================"
echo " Deploying with Helm"
echo "========================================"
helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    "${HELM_VALUES[@]}" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 5m

echo ""
echo "========================================"
echo " Deployment complete"
echo "========================================"
echo ""
echo "Check your ingress hosts in values (or values-local.yaml)."
echo ""
echo "To test ingest:"
echo '  curl -X POST http://<ingest-host>/v1/ingest/devices \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"records": [{"device_id": "lab-spine1", "hostname": "spine1.lab", "platform": "eos"}]}'"'"''
