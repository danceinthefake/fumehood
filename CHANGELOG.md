# Changelog

## 0.1.1 — 2026-09-27

Hardening after a production-readiness review.

- **Fixed — data loss:** `INSERT … ON CONFLICT DO UPDATE` is blocked. It
  overwrote rows without backing them up, and its undo deleted them.
- **Fixed — security:** in `ssh_tunnel` / `dev` mode, requests must name a
  local host, so a page using DNS rebinding can't act as you. API `POST`s
  must be JSON, which cross-site forms can't send.
- **Fixed — cancel:** a late cancel retry could stop the next query on the
  same pooled connection, possibly someone else's. Cancels now only hit
  their own transaction.
- A commit changes exactly the rows its dry run showed (`rows_token`), not
  just as many.
- A restore never overwrites later changes: it's refused if the rows
  changed since the commit, or were already restored.
- Results are streamed; reads stop at about 10 MB, and oversized writes are
  refused without loading every row.
- Dry runs warn about triggers and cascading foreign keys, which change
  other tables that aren't backed up.
- Audit entries are also logged (journal / container logs); `/health`
  checks the audit store; CI workflow.

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
