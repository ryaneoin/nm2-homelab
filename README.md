# nm2-homelab

Network state ingest pipeline. Receives batched network telemetry from Cribl via REST API, stores normalised relational state in PostgreSQL, monitors with Prometheus, and visualises with Grafana.

## Architecture

```
Cribl (external) ──HTTP POST──▶ Ingress ──▶ Ingest API (FastAPI)
                                                    │
                                              ┌─────▼─────┐
                                              │ PostgreSQL │
                                              └─────┬─────┘
                                                    │
                                              Grafana (read-only)
                                                ▲
                                                │
                                           Prometheus
```

### Pod: nm2-ingest

- **Init container** (`db-provisioner`): Idempotently provisions roles (`nm2_ingest` r/w, `nm2_grafana` r/o), schema, tables, indexes, grants. Runs on every pod start; safe to repeat.
- **Main container** (`ingest-api`): FastAPI service accepting batched upserts on typed endpoints (`/v1/ingest/devices`, `/v1/ingest/interfaces`, etc.)

### Database Schema (nm2)

Relational tables normalised in the style of Batfish:

| Table | Upsert Key | Purpose |
|---|---|---|
| `devices` | `device_id` | Device inventory |
| `interfaces` | `(device_id, name)` | Interface state + counters |
| `bgp_peers` | `(device_id, vrf, peer_ip)` | BGP peer state |
| `lldp_neighbors` | `(device_id, local_interface)` | LLDP adjacency |
| `routes` | `(device_id, vrf, prefix, protocol, next_hop, next_hop_interface)` | RIB entries |
| `events` | append-only | Time-series events/syslogs |

### Prometheus

Standalone Prometheus instance with persistent storage and Kubernetes service discovery. Configured to scrape the ingest API and any pod annotated with `prometheus.io/scrape: "true"`. Grafana uses Prometheus as its default datasource.

### Secrets Model

Home lab uses Kubernetes Secrets directly. The secrets template (`templates/secrets.yaml`) is the **single swap point** for production — replace with `SecretProviderClass` (Azure Key Vault CSI) or `ExternalSecret` CRDs (External Secrets Operator). The file contains detailed migration comments with complete example CRDs for both approaches.

**Key contract** — all Deployments reference exactly two Secrets by name:

| Secret Name | Keys |
|---|---|
| `nm2-db-credentials` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_ADMIN_URI`, `INGEST_PASSWORD`, `INGEST_DB_URI`, `GRAFANA_PASSWORD`, `GRAFANA_DB_URI` |
| `nm2-grafana-credentials` | `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` |

As long as the production secret source creates k8s Secrets with these exact names and keys, no other template changes are required.

## Prerequisites

- k3s cluster (Traefik ingress controller included)
- Docker (for building images)
- Helm 3
- `kubectl` configured for the target cluster

## Quick Start

```bash
# 1. Edit secrets in values.yaml
vim helm/nm2-homelab/values.yaml

# 2. Deploy (builds images, loads into k3s, helm install)
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# 3. Add DNS entries
echo "<K3S_NODE_IP>  ingest.nm2.local grafana.nm2.local prometheus.nm2.local" | sudo tee -a /etc/hosts

# 4. Verify
curl http://ingest.nm2.local/healthz
open http://grafana.nm2.local
open http://prometheus.nm2.local
```

## API Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/ingest/devices` | Upsert device inventory |
| `POST` | `/v1/ingest/interfaces` | Upsert interface state |
| `POST` | `/v1/ingest/bgp_peers` | Upsert BGP peer state |
| `POST` | `/v1/ingest/lldp_neighbors` | Upsert LLDP neighbors |
| `POST` | `/v1/ingest/routes` | Upsert routes |
| `POST` | `/v1/ingest/events` | Append events |
| `GET` | `/healthz` | Liveness probe |
| `GET` | `/readyz` | Readiness probe (checks PG pool) |

All POST endpoints accept `{"records": [...]}` and return `{"accepted": N, "errors": [...]}`.

## Production Notes (Azure)

| Concern | Homelab | Production |
|---|---|---|
| Secrets | `values.yaml` → k8s Secret | Key Vault → CSI driver or ESO → k8s Secret |
| PostgreSQL | In-cluster (this chart) | Azure Flexible Server via Terraform |
| Ingress | Traefik (k3s) | NGINX / App Gateway Ingress Controller |
| Deployment | `deploy.sh` / manual Helm | ArgoCD (chart is compatible as-is) |
| Storage class | `local-path` | `managed-csi` |
| Identity | N/A | Managed Identity for Key Vault, PG AAD auth |
