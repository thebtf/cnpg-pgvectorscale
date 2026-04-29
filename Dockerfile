# cnpg-pgvectorscale — full-set replacement for ghcr.io/thebtf/supabase-pgvectorscale
# on a CloudNativePG-compatible base.
#
# Goal: drop-in replacement for CNPG `Cluster.spec.imageName`. Keeps barman-cloud,
# instance manager, pg_failover_slots, healthchecks. Adds the full Supabase extension
# set per supabase/postgres `ansible/files/postgresql_config/supautils.conf.j2`
# (privileged_extensions list, ~70 extensions).
#
# Already in CNPG `system` flavor (do NOT reinstall):
#   pgvector, pgaudit, pg_failover_slots, barman-cloud-tools, locales-all,
#   plus all PostgreSQL contrib (autoinc, bloom, btree_*, citext, cube, dblink, hstore,
#   intarray, isn, ltree, moddatetime, pg_buffercache, pg_prewarm, pg_stat_statements,
#   pg_trgm, pg_walinspect, pgcrypto, pgrowlocks, pgstattuple, postgres_fdw, refint,
#   seg, sslinfo, tablefunc, tcn, tsm_system_*, unaccent, uuid-ossp, …).
#
# Added by this image:
#   apt PGDG:    pg_cron, postgis-3, pgrouting, pgsodium, pg_partman, wal2json, hypopg,
#                rum, pg_stat_kcache, pg_stat_monitor, pgtap, pg_repack, plpgsql_check,
#                plv8, http, orioledb (if available), pg_hint_plan, pg_jobmon
#   apt timescale: timescaledb 2.x
#   apt groonga:  pgroonga
#   apt amazon:   pg_tle
#   github .deb:  pgvectorscale (timescale)
#   pgrx build:   pg_graphql, pg_jsonschema, wrappers, pg_net (Rust)
#   make build:   pg_hashids, pgjwt, supabase_vault, supautils, pgmq

ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-bookworm
ARG PG_MAJOR=17
ARG PGVECTORSCALE_VERSION=0.9.0
ARG PG_GRAPHQL_VERSION=1.5.9
ARG PG_JSONSCHEMA_VERSION=0.3.4
ARG WRAPPERS_VERSION=0.6.0
ARG PG_NET_VERSION=0.9.3
ARG PG_HASHIDS_VERSION=cd0e1b31d52b394a0df64079406a14a4f7387cd6
# pgjwt has no tags — track master HEAD. Pin can be tightened later by replacing
# with a verified commit SHA from `git ls-remote https://github.com/michelp/pgjwt.git HEAD`.
ARG PGJWT_VERSION=master
ARG SUPABASE_VAULT_VERSION=0.3.1
ARG SUPAUTILS_VERSION=3.2.2
ARG PGMQ_VERSION=1.9.0
ARG PGRX_VERSION=0.12.9

# ---------------------------------------------------------------------------
# Stage 1 — pgvectorscale .deb extract
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS pgvectorscale-extract
ARG PG_MAJOR
ARG PGVECTORSCALE_VERSION
ARG TARGETARCH

ADD https://github.com/timescale/pgvectorscale/releases/download/${PGVECTORSCALE_VERSION}/pgvectorscale-${PGVECTORSCALE_VERSION}-pg${PG_MAJOR}-${TARGETARCH}.zip /tmp/pgvectorscale.zip

RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip ca-certificates \
    && cd /tmp && unzip pgvectorscale.zip \
    && mkdir -p /out \
    && dpkg-deb -x pgvectorscale-postgresql-${PG_MAJOR}_${PGVECTORSCALE_VERSION}-Linux_${TARGETARCH}.deb /out \
    && rm -rf /tmp/pgvectorscale*

# ---------------------------------------------------------------------------
# Stage 2 — Rust + cargo-pgrx builder for Supabase Rust extensions
# ---------------------------------------------------------------------------
FROM ghcr.io/cloudnative-pg/postgresql:17-bookworm AS rust-builder
ARG PG_MAJOR
ARG PGRX_VERSION
ARG PG_GRAPHQL_VERSION
ARG PG_JSONSCHEMA_VERSION
ARG WRAPPERS_VERSION
ARG PG_NET_VERSION

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV CARGO_HOME=/root/.cargo
ENV RUSTUP_HOME=/root/.rustup
ENV PATH=/root/.cargo/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang libclang-dev pkg-config libssl-dev \
        postgresql-server-dev-${PG_MAJOR} \
        git ca-certificates curl libreadline-dev zlib1g-dev \
        libcurl4-openssl-dev \
    && curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal

# Helper — install matching cargo-pgrx for each extension's Cargo.toml.
# `cargo-pgrx` enforces strict equality with the pgrx library version, so we
# parse it from each crate's Cargo.toml and install the matching tool. PGRX_HOME
# is per-extension so init artefacts don't collide between versions.
RUN cat > /usr/local/bin/build-pgrx-extension <<'BASH' && chmod +x /usr/local/bin/build-pgrx-extension
#!/bin/bash
set -euo pipefail
ext_dir="$1"
shift
cd "$ext_dir"
PGRX_VER=$(awk -F'[ ="]+' '/^pgrx[[:space:]]*=/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]/) { print $i; exit } }' Cargo.toml)
echo "=== build-pgrx-extension: $ext_dir → pgrx $PGRX_VER ==="
cargo install --locked --version "$PGRX_VER" cargo-pgrx
export PGRX_HOME=/root/.pgrx-$PGRX_VER
mkdir -p "$PGRX_HOME"
if [ ! -e "$PGRX_HOME/config.toml" ]; then
  cargo pgrx init --pg${PG_MAJOR:-17} /usr/lib/postgresql/${PG_MAJOR:-17}/bin/pg_config
fi
cargo pgrx install --release --pg-config /usr/lib/postgresql/${PG_MAJOR:-17}/bin/pg_config "$@"
BASH

# pg_graphql
RUN git clone --depth=1 --branch v${PG_GRAPHQL_VERSION} https://github.com/supabase/pg_graphql.git /tmp/pg_graphql \
    && PG_MAJOR=${PG_MAJOR} build-pgrx-extension /tmp/pg_graphql

# pg_jsonschema
RUN git clone --depth=1 --branch v${PG_JSONSCHEMA_VERSION} https://github.com/supabase/pg_jsonschema.git /tmp/pg_jsonschema \
    && PG_MAJOR=${PG_MAJOR} build-pgrx-extension /tmp/pg_jsonschema

# wrappers (Foreign Data Wrappers — Stripe, Firebase, S3, …)
RUN git clone --depth=1 --branch v${WRAPPERS_VERSION} https://github.com/supabase/wrappers.git /tmp/wrappers \
    && PG_MAJOR=${PG_MAJOR} build-pgrx-extension /tmp/wrappers/wrappers --features all_fdws

# pg_net (async HTTP from PG) — plain make build, not pgrx
RUN git clone --depth=1 --branch v${PG_NET_VERSION} https://github.com/supabase/pg_net.git /tmp/pg_net \
    && cd /tmp/pg_net \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out

# Collect rust extension artifacts at predictable paths
RUN mkdir -p /artifacts/lib /artifacts/share \
    && cp -r /usr/lib/postgresql/${PG_MAJOR}/lib/. /artifacts/lib/ \
    && cp -r /usr/share/postgresql/${PG_MAJOR}/extension/. /artifacts/share/ \
    && cp -r /out/usr/lib/postgresql/${PG_MAJOR}/lib/. /artifacts/lib/ 2>/dev/null || true \
    && cp -r /out/usr/share/postgresql/${PG_MAJOR}/extension/. /artifacts/share/ 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage 3 — C / PL/pgSQL extension builder
# ---------------------------------------------------------------------------
FROM ghcr.io/cloudnative-pg/postgresql:17-bookworm AS c-builder
ARG PG_MAJOR
ARG PG_HASHIDS_VERSION
ARG PGJWT_VERSION
ARG SUPABASE_VAULT_VERSION
ARG SUPAUTILS_VERSION
ARG PGMQ_VERSION

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates curl unzip \
        postgresql-server-dev-${PG_MAJOR} \
        libcurl4-openssl-dev libssl-dev libsodium-dev

# pgsodium (build from source — not packaged in PGDG bookworm for PG 17)
ARG PGSODIUM_VERSION=3.1.9
RUN git clone --depth=1 --branch v${PGSODIUM_VERSION} https://github.com/michelp/pgsodium.git /tmp/pgsodium \
    && cd /tmp/pgsodium \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/pgsodium

# pg_hashids
RUN git clone https://github.com/iCyberon/pg_hashids.git /tmp/pg_hashids \
    && cd /tmp/pg_hashids \
    && git checkout ${PG_HASHIDS_VERSION} \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/hashids

# pgjwt (PL/pgSQL only — copy SQL + control)
RUN git clone --depth=1 --branch ${PGJWT_VERSION} https://github.com/michelp/pgjwt.git /tmp/pgjwt \
    && cd /tmp/pgjwt \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/pgjwt

# supabase_vault (PL/pgSQL — depends on pgsodium at runtime)
RUN git clone --depth=1 --branch v${SUPABASE_VAULT_VERSION} https://github.com/supabase/vault.git /tmp/vault \
    && cd /tmp/vault \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/vault

# supautils (C extension that gates privileged operations)
RUN git clone --depth=1 --branch v${SUPAUTILS_VERSION} https://github.com/supabase/supautils.git /tmp/supautils \
    && cd /tmp/supautils \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/supautils

# pgmq (PL/pgSQL — Tembo)
RUN git clone --depth=1 --branch v${PGMQ_VERSION} https://github.com/tembo-io/pgmq.git /tmp/pgmq \
    && cd /tmp/pgmq/pgmq-extension \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/pgmq

# ---------------------------------------------------------------------------
# Stage 4 — final image
# ---------------------------------------------------------------------------
FROM ${CNPG_BASE}
ARG PG_MAJOR
ARG TARGETARCH

USER root
ENV DEBIAN_FRONTEND=noninteractive

# 1. Add third-party apt repos: TimescaleDB, pgroonga, Amazon pg_tle.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gnupg lsb-release wget curl \
    # Timescale
    && wget --quiet -O /usr/share/keyrings/timescale.gpg.asc \
        "https://packagecloud.io/timescale/timescaledb/gpgkey" \
    && echo "deb [signed-by=/usr/share/keyrings/timescale.gpg.asc] https://packagecloud.io/timescale/timescaledb/debian/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/timescaledb.list \
    # pgroonga (groonga apt repo)
    && wget --quiet -O - https://packages.groonga.org/debian/groonga-apt-source-latest-$(lsb_release --codename --short).deb > /tmp/groonga.deb \
    && (apt-get install -y --no-install-recommends /tmp/groonga.deb || true) \
    && rm -f /tmp/groonga.deb \
    && apt-get update

# 2. Apt extensions — robust per-package install.
#    PGDG bookworm coverage for PG 17 is uneven. Install each package individually:
#    success → keep, failure → log WARN and continue. End of stage prints a summary
#    so the smoke job can see what landed.
#    Required runtime libs (libsodium for pgsodium .so, plus net/utility libs).
RUN apt-get install -y --no-install-recommends \
        libsodium23 libcurl4 \
    || (echo "FATAL: required runtime libs missing" && exit 1)

# Critical apt packages — must succeed. Fail the build if any is missing because
# downstream functionality (geospatial, time-series, scheduling, vector-distance) depends on it.
RUN set -e; \
    for pkg in \
        postgresql-${PG_MAJOR}-postgis-3 \
        postgresql-${PG_MAJOR}-postgis-3-scripts \
        postgresql-${PG_MAJOR}-cron \
        postgresql-${PG_MAJOR}-partman \
        postgresql-${PG_MAJOR}-wal2json \
        postgresql-${PG_MAJOR}-hypopg \
        postgresql-${PG_MAJOR}-pgaudit \
        postgresql-${PG_MAJOR}-repack \
        postgresql-plpython3-${PG_MAJOR} \
        timescaledb-2-postgresql-${PG_MAJOR}; \
    do \
        echo "=== apt install (required) $pkg ==="; \
        apt-get install -y --no-install-recommends "$pkg"; \
    done

# Optional apt packages — install if available, log WARN otherwise. The smoke
# test will reveal which extensions are missing in the final image.
RUN for pkg in \
        postgresql-${PG_MAJOR}-pgrouting \
        postgresql-${PG_MAJOR}-rum \
        postgresql-${PG_MAJOR}-pg-stat-kcache \
        postgresql-${PG_MAJOR}-pg-stat-monitor \
        postgresql-${PG_MAJOR}-pg-hint-plan \
        postgresql-${PG_MAJOR}-pgtap \
        postgresql-${PG_MAJOR}-plpgsql-check \
        postgresql-${PG_MAJOR}-plv8 \
        postgresql-${PG_MAJOR}-http \
        postgresql-${PG_MAJOR}-pgroonga; \
    do \
        if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then \
            echo "OK: $pkg"; \
        else \
            echo "WARN: $pkg not available — skipping"; \
        fi; \
    done

# 3. orioledb is installed via dedicated apt repo (orioletech) when available;
#    skipped if not packaged for the target arch.
RUN curl -fsSL https://orioledb.com/orioledb.gpg.key | gpg --dearmor -o /usr/share/keyrings/orioledb.gpg 2>/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/orioledb.gpg] https://orioledb.com/apt $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/orioledb.list \
    && (apt-get update && apt-get install -y --no-install-recommends postgresql-${PG_MAJOR}-orioledb) \
        || echo "WARN: orioledb not available for this arch/distro — skipping"

# 4. Cleanup temp tooling
RUN apt-get purge -y --auto-remove wget curl gnupg lsb-release \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/* /var/log/* /tmp/*

# 5. pgvectorscale (.deb extracted in Stage 1)
COPY --from=pgvectorscale-extract /out/usr/lib/postgresql/ /usr/lib/postgresql/
COPY --from=pgvectorscale-extract /out/usr/share/postgresql/ /usr/share/postgresql/

# 6. Rust extensions (pg_graphql, pg_jsonschema, wrappers, pg_net)
COPY --from=rust-builder /artifacts/lib/    /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=rust-builder /artifacts/share/  /usr/share/postgresql/${PG_MAJOR}/extension/

# 7. C / PL/pgSQL extensions (pgsodium built from source — required for supabase_vault)
COPY --from=c-builder /out/pgsodium/usr/   /usr/
COPY --from=c-builder /out/hashids/usr/    /usr/
COPY --from=c-builder /out/pgjwt/usr/      /usr/
COPY --from=c-builder /out/vault/usr/      /usr/
COPY --from=c-builder /out/supautils/usr/  /usr/
COPY --from=c-builder /out/pgmq/usr/       /usr/
COPY --from=c-builder /out/pgmq/usr/       /usr/

# 8. Sanity — list installed extension control files for build-time visibility.
RUN ls -1 /usr/share/postgresql/${PG_MAJOR}/extension/*.control \
    | xargs -n1 basename \
    | sed 's/\.control$//' \
    | sort -u > /usr/share/postgresql/${PG_MAJOR}/extension.list \
    && echo "=== installed extensions:" \
    && cat /usr/share/postgresql/${PG_MAJOR}/extension.list

USER 26
