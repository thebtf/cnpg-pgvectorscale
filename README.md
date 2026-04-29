# cnpg-pgvectorscale

CloudNativePG-compatible PostgreSQL container image with the full Supabase extension set
plus pgvectorscale (DiskANN). Drop-in replacement for `Cluster.spec.imageName` in any
CNPG cluster — barman-cloud, instance manager, healthchecks, pg_failover_slots all work
unchanged.

## Why

The official CNPG `system` image carries a small extension set: `pgvector`, `pgaudit`,
`pg_failover_slots`, plus all PostgreSQL contribs. The Supabase distribution ships ~70
extensions across geospatial, time-series, vector search, search, FDWs, and platform
plumbing. This image adds the missing ~50 extensions on top of the CNPG base, so a CNPG
cluster gains feature parity with a self-hosted Supabase Postgres deployment without
giving up CNPG operator semantics.

## What's inside (delta vs CNPG base)

**apt — PGDG + Timescale + groonga + orioledb:**
postgis-3, postgis-3-scripts, postgis-tiger-geocoder, postgis-topology, pgrouting,
timescaledb, pg_cron, pg_partman, pgsodium, wal2json, hypopg, rum, pg_stat_kcache,
pg_stat_monitor, pg_hint_plan, pgtap, pg_repack, plpgsql_check, plpython3, plv8,
http, pgroonga, orioledb (where available).

**pgvectorscale** (timescale GitHub releases): DiskANN, SBQ for high-dim vectors.

**Rust + cargo-pgrx (built from source):**
pg_graphql, pg_jsonschema, wrappers (all FDWs), pg_net.

**C / PL/pgSQL (built from source):**
pg_hashids, pgjwt, supabase_vault, supautils, pgmq.

## Use with CNPG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
  namespace: data
spec:
  instances: 1
  imageName: ghcr.io/thebtf/cnpg-pgvectorscale:17
  postgresql:
    shared_preload_libraries:
      - timescaledb
      - pg_cron
      - pg_stat_kcache
      - pg_stat_monitor
      - pgaudit
      - supautils
      - pgsodium
    parameters:
      cron.database_name: app
  storage:
    size: 50Gi
```

Then per database:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_graphql;
-- … etc
```

## Tags

- `:17` / `:latest` — main branch HEAD on PG 17
- `:vX.Y.Z` — semver release
- `:sha-<7>` — pinned by commit
- `:17.6.X` — pinned by Postgres minor version (when published)

## Build

GitHub Actions multi-stage buildx (linux/amd64). Runs on every push to main + tags.
Image published to `ghcr.io/thebtf/cnpg-pgvectorscale`.

Local:
```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17 \
  --build-arg PG_MAJOR=17 \
  --build-arg PGVECTORSCALE_VERSION=0.9.0 \
  -t cnpg-pgvectorscale:dev .
```

## Compatibility

- PostgreSQL: **17.x** (CNPG `:17` base tracks minor releases)
- CNPG operator: any version that accepts custom `imageName` (≥1.18)
- Architectures: `linux/amd64` (arm64 build planned once amd64 recipe stabilises)

## License

Apache-2.0 for the build recipe. Each bundled extension keeps its own upstream license —
see the corresponding upstream repo for details.
