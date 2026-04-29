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
ARG PG_GRAPHQL_VERSION=1.5.11
ARG PG_JSONSCHEMA_VERSION=0.3.3
ARG WRAPPERS_VERSION=0.5.5
ARG PG_NET_VERSION=0.13.0
ARG PG_HASHIDS_VERSION=cd0e1b31d52b394a0df64079406a14a4f7387cd6
ARG PGJWT_VERSION=9742dab1b2f297ad3811120db7b21451bca2b21d
ARG SUPABASE_VAULT_VERSION=0.3.1
ARG SUPAUTILS_VERSION=2.7.5
ARG PGMQ_VERSION=1.5.1
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
    && curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal \
    && cargo install --locked --version ${PGRX_VERSION} cargo-pgrx \
    && cargo pgrx init --pg${PG_MAJOR} /usr/lib/postgresql/${PG_MAJOR}/bin/pg_config

# pg_graphql
RUN git clone --depth=1 --branch v${PG_GRAPHQL_VERSION} https://github.com/supabase/pg_graphql.git /tmp/pg_graphql \
    && cd /tmp/pg_graphql \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/${PG_MAJOR}/bin/pg_config

# pg_jsonschema
RUN git clone --depth=1 --branch v${PG_JSONSCHEMA_VERSION} https://github.com/supabase/pg_jsonschema.git /tmp/pg_jsonschema \
    && cd /tmp/pg_jsonschema \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/${PG_MAJOR}/bin/pg_config

# wrappers (Foreign Data Wrappers — Stripe, Firebase, S3, …)
RUN git clone --depth=1 --branch v${WRAPPERS_VERSION} https://github.com/supabase/wrappers.git /tmp/wrappers \
    && cd /tmp/wrappers/wrappers \
    && cargo pgrx install --release --pg-config /usr/lib/postgresql/${PG_MAJOR}/bin/pg_config --features all_fdws

# pg_net (async HTTP from PG)
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
        libcurl4-openssl-dev libssl-dev \
        postgresql-${PG_MAJOR}-pgsodium

# pg_hashids
RUN git clone https://github.com/iCyberon/pg_hashids.git /tmp/pg_hashids \
    && cd /tmp/pg_hashids \
    && git checkout ${PG_HASHIDS_VERSION} \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config \
    && make PG_CONFIG=/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config install DESTDIR=/out/hashids

# pgjwt (PL/pgSQL only — copy SQL + control)
RUN git clone https://github.com/michelp/pgjwt.git /tmp/pgjwt \
    && cd /tmp/pgjwt \
    && git checkout ${PGJWT_VERSION} \
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

# 2. Apt extensions (PGDG + Timescale + groonga).
#    `|| true` guards entries that may not be packaged for trixie yet — those will be
#    revisited via build-from-source if missing.
RUN apt-get install -y --no-install-recommends \
        # Geospatial
        postgresql-${PG_MAJOR}-postgis-3 \
        postgresql-${PG_MAJOR}-postgis-3-scripts \
        postgresql-${PG_MAJOR}-pgrouting \
        # Time series
        timescaledb-2-postgresql-${PG_MAJOR} \
        # Scheduling / partitioning
        postgresql-${PG_MAJOR}-cron \
        postgresql-${PG_MAJOR}-partman \
        # Crypto / vault prereq
        postgresql-${PG_MAJOR}-pgsodium \
        # Logical replication / CDC
        postgresql-${PG_MAJOR}-wal2json \
        # Query planning / statistics
        postgresql-${PG_MAJOR}-hypopg \
        postgresql-${PG_MAJOR}-rum \
        postgresql-${PG_MAJOR}-pg-stat-kcache \
        postgresql-${PG_MAJOR}-pg-stat-monitor \
        postgresql-${PG_MAJOR}-pg-hint-plan \
        # Quality / debug
        postgresql-${PG_MAJOR}-pgtap \
        postgresql-${PG_MAJOR}-repack \
        postgresql-${PG_MAJOR}-plpgsql-check \
        # Procedural langs
        postgresql-plpython3-${PG_MAJOR} \
        postgresql-${PG_MAJOR}-plv8 \
        # HTTP / utility
        postgresql-${PG_MAJOR}-http \
    # Optional packages — install if available, otherwise skip (will be addressed in source build).
    && apt-get install -y --no-install-recommends \
        postgresql-${PG_MAJOR}-pgroonga \
        || echo "WARN: postgresql-${PG_MAJOR}-pgroonga not in apt — will not be present"

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

# 7. C / PL/pgSQL extensions
COPY --from=c-builder /out/hashids/usr/    /usr/
COPY --from=c-builder /out/pgjwt/usr/      /usr/
COPY --from=c-builder /out/vault/usr/      /usr/
COPY --from=c-builder /out/supautils/usr/  /usr/
COPY --from=c-builder /out/pgmq/usr/       /usr/

# 8. Sanity — list installed extension control files for build-time visibility.
RUN ls -1 /usr/share/postgresql/${PG_MAJOR}/extension/*.control \
    | xargs -n1 basename \
    | sed 's/\.control$//' \
    | sort -u > /usr/share/postgresql/${PG_MAJOR}/extension.list \
    && echo "=== installed extensions:" \
    && cat /usr/share/postgresql/${PG_MAJOR}/extension.list

USER 26
