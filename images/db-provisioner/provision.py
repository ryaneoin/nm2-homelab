#!/usr/bin/env python3
"""
DB Provisioner — init container for nm2-homelab.

Idempotently creates:
  - Roles: nm2_ingest (read/write), nm2_grafana (read-only)
  - Schema: nm2
  - Relational tables (Batfish-normalised network state)
  - Grants and default privileges

Connects as the postgres admin user.
Safe to re-run on every pod restart.
"""

import os
import sys
import time
import psycopg2

ADMIN_URI = os.environ["POSTGRES_ADMIN_URI"]
INGEST_PASSWORD = os.environ["INGEST_PASSWORD"]
GRAFANA_PASSWORD = os.environ["GRAFANA_PASSWORD"]

MAX_RETRIES = 30
RETRY_DELAY = 2

# ---------------------------------------------------------------------------
# Schema DDL
# ---------------------------------------------------------------------------

ROLES_SQL = """
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'nm2_ingest') THEN
        CREATE ROLE nm2_ingest WITH LOGIN PASSWORD '{ingest_pw}';
    ELSE
        ALTER ROLE nm2_ingest WITH PASSWORD '{ingest_pw}';
    END IF;

    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'nm2_grafana') THEN
        CREATE ROLE nm2_grafana WITH LOGIN PASSWORD '{grafana_pw}';
    ELSE
        ALTER ROLE nm2_grafana WITH PASSWORD '{grafana_pw}';
    END IF;
END
$$;
"""

SCHEMA_SQL = "CREATE SCHEMA IF NOT EXISTS nm2;"

TABLES_SQL = [
    # ----- devices -----
    """
    CREATE TABLE IF NOT EXISTS nm2.devices (
        device_id       TEXT PRIMARY KEY,
        hostname        TEXT NOT NULL,
        platform        TEXT,
        os_version      TEXT,
        serial_number   TEXT,
        mgmt_ip         INET,
        model           TEXT,
        uptime_seconds  BIGINT,
        last_seen       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """,

    # ----- interfaces -----
    """
    CREATE TABLE IF NOT EXISTS nm2.interfaces (
        id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id       TEXT NOT NULL REFERENCES nm2.devices(device_id) ON DELETE CASCADE,
        name            TEXT NOT NULL,
        admin_status    TEXT,
        oper_status     TEXT,
        speed_mbps      INTEGER,
        mtu             INTEGER,
        ip_address      INET,
        prefix_length   SMALLINT,
        description     TEXT,
        if_index        INTEGER,
        mac_address     MACADDR,
        in_octets       BIGINT,
        out_octets      BIGINT,
        in_errors       BIGINT,
        out_errors      BIGINT,
        last_updated    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (device_id, name)
    );
    """,

    # ----- bgp_peers -----
    """
    CREATE TABLE IF NOT EXISTS nm2.bgp_peers (
        id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id           TEXT NOT NULL REFERENCES nm2.devices(device_id) ON DELETE CASCADE,
        vrf                 TEXT NOT NULL DEFAULT 'default',
        local_as            BIGINT NOT NULL,
        peer_ip             INET NOT NULL,
        peer_as             BIGINT NOT NULL,
        state               TEXT,
        prefixes_received   INTEGER,
        prefixes_sent       INTEGER,
        uptime_seconds      BIGINT,
        router_id           INET,
        last_updated        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (device_id, vrf, peer_ip)
    );
    """,

    # ----- lldp_neighbors -----
    """
    CREATE TABLE IF NOT EXISTS nm2.lldp_neighbors (
        id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id           TEXT NOT NULL REFERENCES nm2.devices(device_id) ON DELETE CASCADE,
        local_interface     TEXT NOT NULL,
        remote_device       TEXT,
        remote_interface    TEXT,
        remote_platform     TEXT,
        remote_mgmt_ip      INET,
        last_updated        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (device_id, local_interface)
    );
    """,

    # ----- routes -----
    """
    CREATE TABLE IF NOT EXISTS nm2.routes (
        id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id           TEXT NOT NULL REFERENCES nm2.devices(device_id) ON DELETE CASCADE,
        vrf                 TEXT NOT NULL DEFAULT 'default',
        prefix              CIDR NOT NULL,
        next_hop            INET,
        next_hop_interface  TEXT,
        protocol            TEXT NOT NULL DEFAULT 'unknown',
        metric              INTEGER,
        preference          INTEGER,
        tag                 BIGINT,
        last_updated        TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """,

    # ----- events (append-only time-series) -----
    """
    CREATE TABLE IF NOT EXISTS nm2.events (
        id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id       TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        timestamp       TIMESTAMPTZ NOT NULL,
        severity        SMALLINT,
        feature         TEXT,
        summary         TEXT,
        detail          TEXT,
        received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    """,
]

# Routes use a functional unique index to handle nullable next_hop
INDEXES_SQL = [
    "CREATE INDEX IF NOT EXISTS idx_interfaces_device ON nm2.interfaces (device_id);",
    "CREATE INDEX IF NOT EXISTS idx_bgp_peers_device ON nm2.bgp_peers (device_id);",
    "CREATE INDEX IF NOT EXISTS idx_lldp_device ON nm2.lldp_neighbors (device_id);",
    "CREATE INDEX IF NOT EXISTS idx_routes_device ON nm2.routes (device_id);",
    "CREATE INDEX IF NOT EXISTS idx_routes_prefix ON nm2.routes (prefix);",
    """CREATE UNIQUE INDEX IF NOT EXISTS idx_routes_upsert
       ON nm2.routes (device_id, vrf, prefix, protocol, COALESCE(next_hop::TEXT, ''), COALESCE(next_hop_interface, ''));""",
    "CREATE INDEX IF NOT EXISTS idx_events_device_ts ON nm2.events (device_id, timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_ts ON nm2.events (timestamp);",
]

GRANTS_SQL = """
-- Schema access
GRANT USAGE ON SCHEMA nm2 TO nm2_ingest, nm2_grafana;

-- nm2_ingest: read/write on all current tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA nm2 TO nm2_ingest;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA nm2 TO nm2_ingest;

-- nm2_grafana: read-only on all current tables
GRANT SELECT ON ALL TABLES IN SCHEMA nm2 TO nm2_grafana;

-- Default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA nm2
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nm2_ingest;
ALTER DEFAULT PRIVILEGES IN SCHEMA nm2
    GRANT USAGE ON SEQUENCES TO nm2_ingest;
ALTER DEFAULT PRIVILEGES IN SCHEMA nm2
    GRANT SELECT ON TABLES TO nm2_grafana;
"""


def wait_for_postgres(uri: str) -> psycopg2.extensions.connection:
    """Retry connection until postgres is ready."""
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            conn = psycopg2.connect(uri)
            conn.autocommit = True
            print(f"[provisioner] Connected to postgres (attempt {attempt})")
            return conn
        except psycopg2.OperationalError as e:
            print(f"[provisioner] Waiting for postgres (attempt {attempt}/{MAX_RETRIES}): {e}")
            time.sleep(RETRY_DELAY)
    print("[provisioner] FATAL: Could not connect to postgres")
    sys.exit(1)


def provision(conn: psycopg2.extensions.connection) -> None:
    cur = conn.cursor()

    # Roles (passwords injected via format — these come from k8s secrets, not user input)
    print("[provisioner] Creating/updating roles...")
    role_sql = ROLES_SQL.format(
        ingest_pw=INGEST_PASSWORD,
        grafana_pw=GRAFANA_PASSWORD,
    )
    cur.execute(role_sql)

    # Schema
    print("[provisioner] Creating schema...")
    cur.execute(SCHEMA_SQL)

    # Tables
    print("[provisioner] Creating tables...")
    for ddl in TABLES_SQL:
        cur.execute(ddl)

    # Indexes
    print("[provisioner] Creating indexes...")
    for idx in INDEXES_SQL:
        cur.execute(idx)

    # Grants
    print("[provisioner] Applying grants...")
    cur.execute(GRANTS_SQL)

    cur.close()
    print("[provisioner] Provisioning complete.")


def main():
    conn = wait_for_postgres(ADMIN_URI)
    try:
        provision(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
