# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Initial multi-stage Dockerfile producing a CNPG-compatible PG 17 image with the full
  Supabase extension set plus pgvectorscale 0.9.0.
- GitHub Actions workflow: linux/amd64 buildx, smoke test on a curated extension list.
- README documenting the delta vs CNPG base.

### Known limitations
- Architecture limited to `linux/amd64` — arm64 build deferred until the amd64 recipe is
  stable end-to-end.
- `orioledb` and `pgroonga` apt installs are best-effort with `|| true` fallback when not
  packaged for the target Debian release. Will move to source builds if persistent gaps
  appear.
- Smoke gate accepts up to 5 extension failures during the first iterations to allow
  visible failure surfaces; tightened to zero failures in v0.2.

### Sources
- CNPG base: `ghcr.io/cloudnative-pg/postgresql:17`
- Supabase extension list: `supabase/postgres ansible/files/postgresql_config/supautils.conf.j2`
- pgvectorscale: `github.com/timescale/pgvectorscale`
- pg_graphql / pg_jsonschema / wrappers / pg_net: `github.com/supabase`
- pg_hashids / pgjwt / supabase_vault / supautils / pgmq: respective upstream repos
