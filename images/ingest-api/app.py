"""
nm2-homelab Ingest API

FastAPI service that accepts batched network state from Cribl (or any HTTP client)
and upserts into PostgreSQL relational tables.

Endpoints:
  POST /v1/ingest/devices        — upsert device inventory
  POST /v1/ingest/interfaces     — upsert interface state
  POST /v1/ingest/bgp_peers      — upsert BGP peer state
  POST /v1/ingest/lldp_neighbors — upsert LLDP neighbor state
  POST /v1/ingest/routes         — upsert routing table state
  POST /v1/ingest/events         — append time-series events
  GET  /healthz                  — liveness probe
  GET  /readyz                   — readiness probe (checks PG pool)
"""

import os
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import asyncpg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("ingest-api")

INGEST_DB_URI = os.environ["INGEST_DB_URI"]
POOL_MIN = int(os.environ.get("POOL_MIN", "2"))
POOL_MAX = int(os.environ.get("POOL_MAX", "10"))

pool: Optional[asyncpg.Pool] = None


# ---------------------------------------------------------------------------
# Lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    logger.info("Creating connection pool...")
    pool = await asyncpg.create_pool(INGEST_DB_URI, min_size=POOL_MIN, max_size=POOL_MAX)
    logger.info("Connection pool ready.")
    yield
    logger.info("Closing connection pool...")
    await pool.close()


app = FastAPI(title="nm2-homelab Ingest API", version="0.1.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------

class DeviceRecord(BaseModel):
    device_id: str
    hostname: str
    platform: Optional[str] = None
    os_version: Optional[str] = None
    serial_number: Optional[str] = None
    mgmt_ip: Optional[str] = None
    model: Optional[str] = None
    uptime_seconds: Optional[int] = None


class InterfaceRecord(BaseModel):
    device_id: str
    name: str
    admin_status: Optional[str] = None
    oper_status: Optional[str] = None
    speed_mbps: Optional[int] = None
    mtu: Optional[int] = None
    ip_address: Optional[str] = None
    prefix_length: Optional[int] = None
    description: Optional[str] = None
    if_index: Optional[int] = None
    mac_address: Optional[str] = None
    in_octets: Optional[int] = None
    out_octets: Optional[int] = None
    in_errors: Optional[int] = None
    out_errors: Optional[int] = None


class BgpPeerRecord(BaseModel):
    device_id: str
    vrf: str = "default"
    local_as: int
    peer_ip: str
    peer_as: int
    state: Optional[str] = None
    prefixes_received: Optional[int] = None
    prefixes_sent: Optional[int] = None
    uptime_seconds: Optional[int] = None
    router_id: Optional[str] = None


class LldpNeighborRecord(BaseModel):
    device_id: str
    local_interface: str
    remote_device: Optional[str] = None
    remote_interface: Optional[str] = None
    remote_platform: Optional[str] = None
    remote_mgmt_ip: Optional[str] = None


class RouteRecord(BaseModel):
    device_id: str
    vrf: str = "default"
    prefix: str
    next_hop: Optional[str] = None
    next_hop_interface: Optional[str] = None
    protocol: str = "unknown"
    metric: Optional[int] = None
    preference: Optional[int] = None
    tag: Optional[int] = None


class EventRecord(BaseModel):
    device_id: str
    source_type: str
    timestamp: datetime
    severity: Optional[int] = None
    feature: Optional[str] = None
    summary: Optional[str] = None
    detail: Optional[str] = None


class IngestRequest(BaseModel):
    records: list


class IngestResponse(BaseModel):
    accepted: int
    errors: list[str]


# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    if pool is None:
        raise HTTPException(status_code=503, detail="Pool not initialised")
    try:
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


# ---------------------------------------------------------------------------
# Ingest endpoints
# ---------------------------------------------------------------------------

@app.post("/v1/ingest/devices", response_model=IngestResponse)
async def ingest_devices(payload: dict):
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = DeviceRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.devices (device_id, hostname, platform, os_version,
                        serial_number, mgmt_ip, model, uptime_seconds, last_seen)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
                    ON CONFLICT (device_id) DO UPDATE SET
                        hostname = EXCLUDED.hostname,
                        platform = COALESCE(EXCLUDED.platform, nm2.devices.platform),
                        os_version = COALESCE(EXCLUDED.os_version, nm2.devices.os_version),
                        serial_number = COALESCE(EXCLUDED.serial_number, nm2.devices.serial_number),
                        mgmt_ip = COALESCE(EXCLUDED.mgmt_ip, nm2.devices.mgmt_ip),
                        model = COALESCE(EXCLUDED.model, nm2.devices.model),
                        uptime_seconds = COALESCE(EXCLUDED.uptime_seconds, nm2.devices.uptime_seconds),
                        last_seen = NOW()
                    """,
                    r.device_id, r.hostname, r.platform, r.os_version,
                    r.serial_number, r.mgmt_ip, r.model, r.uptime_seconds,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"device {raw.get('device_id', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)


@app.post("/v1/ingest/interfaces", response_model=IngestResponse)
async def ingest_interfaces(payload: dict):
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = InterfaceRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.interfaces (device_id, name, admin_status, oper_status,
                        speed_mbps, mtu, ip_address, prefix_length, description, if_index,
                        mac_address, in_octets, out_octets, in_errors, out_errors, last_updated)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, NOW())
                    ON CONFLICT (device_id, name) DO UPDATE SET
                        admin_status = COALESCE(EXCLUDED.admin_status, nm2.interfaces.admin_status),
                        oper_status = COALESCE(EXCLUDED.oper_status, nm2.interfaces.oper_status),
                        speed_mbps = COALESCE(EXCLUDED.speed_mbps, nm2.interfaces.speed_mbps),
                        mtu = COALESCE(EXCLUDED.mtu, nm2.interfaces.mtu),
                        ip_address = COALESCE(EXCLUDED.ip_address, nm2.interfaces.ip_address),
                        prefix_length = COALESCE(EXCLUDED.prefix_length, nm2.interfaces.prefix_length),
                        description = COALESCE(EXCLUDED.description, nm2.interfaces.description),
                        if_index = COALESCE(EXCLUDED.if_index, nm2.interfaces.if_index),
                        mac_address = COALESCE(EXCLUDED.mac_address, nm2.interfaces.mac_address),
                        in_octets = EXCLUDED.in_octets,
                        out_octets = EXCLUDED.out_octets,
                        in_errors = EXCLUDED.in_errors,
                        out_errors = EXCLUDED.out_errors,
                        last_updated = NOW()
                    """,
                    r.device_id, r.name, r.admin_status, r.oper_status,
                    r.speed_mbps, r.mtu, r.ip_address, r.prefix_length,
                    r.description, r.if_index, r.mac_address,
                    r.in_octets, r.out_octets, r.in_errors, r.out_errors,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"interface {raw.get('device_id', '?')}:{raw.get('name', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)


@app.post("/v1/ingest/bgp_peers", response_model=IngestResponse)
async def ingest_bgp_peers(payload: dict):
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = BgpPeerRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.bgp_peers (device_id, vrf, local_as, peer_ip, peer_as,
                        state, prefixes_received, prefixes_sent, uptime_seconds, router_id, last_updated)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
                    ON CONFLICT (device_id, vrf, peer_ip) DO UPDATE SET
                        local_as = EXCLUDED.local_as,
                        peer_as = EXCLUDED.peer_as,
                        state = EXCLUDED.state,
                        prefixes_received = EXCLUDED.prefixes_received,
                        prefixes_sent = EXCLUDED.prefixes_sent,
                        uptime_seconds = EXCLUDED.uptime_seconds,
                        router_id = COALESCE(EXCLUDED.router_id, nm2.bgp_peers.router_id),
                        last_updated = NOW()
                    """,
                    r.device_id, r.vrf, r.local_as, r.peer_ip, r.peer_as,
                    r.state, r.prefixes_received, r.prefixes_sent,
                    r.uptime_seconds, r.router_id,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"bgp_peer {raw.get('device_id', '?')}:{raw.get('peer_ip', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)


@app.post("/v1/ingest/lldp_neighbors", response_model=IngestResponse)
async def ingest_lldp_neighbors(payload: dict):
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = LldpNeighborRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.lldp_neighbors (device_id, local_interface, remote_device,
                        remote_interface, remote_platform, remote_mgmt_ip, last_updated)
                    VALUES ($1, $2, $3, $4, $5, $6, NOW())
                    ON CONFLICT (device_id, local_interface) DO UPDATE SET
                        remote_device = EXCLUDED.remote_device,
                        remote_interface = EXCLUDED.remote_interface,
                        remote_platform = EXCLUDED.remote_platform,
                        remote_mgmt_ip = COALESCE(EXCLUDED.remote_mgmt_ip, nm2.lldp_neighbors.remote_mgmt_ip),
                        last_updated = NOW()
                    """,
                    r.device_id, r.local_interface, r.remote_device,
                    r.remote_interface, r.remote_platform, r.remote_mgmt_ip,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"lldp {raw.get('device_id', '?')}:{raw.get('local_interface', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)


@app.post("/v1/ingest/routes", response_model=IngestResponse)
async def ingest_routes(payload: dict):
    """Upsert routes. Uses functional unique index on
    (device_id, vrf, prefix, protocol, coalesce(next_hop), coalesce(next_hop_interface))."""
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = RouteRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.routes (device_id, vrf, prefix, next_hop, next_hop_interface,
                        protocol, metric, preference, tag, last_updated)
                    VALUES ($1, $2, $3::CIDR, $4, $5, $6, $7, $8, $9, NOW())
                    ON CONFLICT (device_id, vrf, prefix, protocol,
                        COALESCE(next_hop::TEXT, ''), COALESCE(next_hop_interface, ''))
                    DO UPDATE SET
                        metric = EXCLUDED.metric,
                        preference = EXCLUDED.preference,
                        tag = EXCLUDED.tag,
                        last_updated = NOW()
                    """,
                    r.device_id, r.vrf, r.prefix, r.next_hop, r.next_hop_interface,
                    r.protocol, r.metric, r.preference, r.tag,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"route {raw.get('device_id', '?')}:{raw.get('prefix', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)


@app.post("/v1/ingest/events", response_model=IngestResponse)
async def ingest_events(payload: dict):
    """Append-only insert into events table."""
    records = payload.get("records", [])
    errors = []
    accepted = 0
    async with pool.acquire() as conn:
        for raw in records:
            try:
                r = EventRecord(**raw)
                await conn.execute(
                    """
                    INSERT INTO nm2.events (device_id, source_type, timestamp,
                        severity, feature, summary, detail, received_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
                    """,
                    r.device_id, r.source_type, r.timestamp,
                    r.severity, r.feature, r.summary, r.detail,
                )
                accepted += 1
            except Exception as e:
                errors.append(f"event {raw.get('device_id', '?')}: {e}")
    return IngestResponse(accepted=accepted, errors=errors)
