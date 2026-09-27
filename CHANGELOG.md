# Changelog

## 0.1.0 — 2026-09-27

First release.

- **Safety:** statements parsed with Postgres's own parser (pg_query) and
  checked against an allowlist; DDL, `TRUNCATE`, writes without `WHERE`,
  data-changing CTEs, `MERGE`, side-effect functions and more are blocked.
  SQL over 100 KB is refused before parsing.
- **Reads** run in a read-only transaction with a row limit and statement
  timeout.
- **Writes** go dry run → confirm → commit. The rows a write changes are
  locked and backed up to CSV (Postgres `COPY`) before the commit, and the
  commit is refused if the row count differs from the dry run.
- **Restore** from any backup, through the same dry run → confirm.
- **Audit:** append-only log in SQLite, written before any change; live in
  the UI over Phoenix Channels.
- **Cancel** a running query from the UI (`pg_cancel_backend`).
- **Access:** Google Cloud IAP (verified JWT) or gcloud SSH tunnel (socket
  owner → OS Login user); no user accounts. Per-database `read_only` /
  `read_write`.
- **Backups** expire after 30 days by default, per database.
- **Install:** Docker image for trying it out; release tarball with
  `install.sh` and a sandboxed systemd unit for a Compute Engine VM.
- Docs in English and Bahasa Indonesia.
