# fumehood — design notes

> Run queries against production databases safely: dangerous statements are
> blocked, every query runs inside a transaction, every action is audited.

Name: the enclosed lab cabinet where chemists handle dangerous substances
behind a glass sash — dangerous production queries run inside a safe
enclosure, nothing escapes.

Status: **design for v1 (2026-09-27)** — decisions and the few open ones in §11.

## 1. Problem

Most teams eventually need someone to look at, or fix, data in production.
What usually happens:

- shared database credentials in a password manager or a `.env`, or a
  bastion host + `psql`;
- nobody reviews the statement before it runs — one `DELETE` without a
  `WHERE`, one `UPDATE` hitting the wrong rows, one query holding a lock on a
  hot table, and production is down;
- no record of who ran what, when, or how many rows it changed;
- personal data (emails, phone numbers, addresses) visible to anyone with
  access.

fumehood is the single door to production data: people reach it through
Google Cloud (IAP or an SSH tunnel), write SQL in a browser, and fumehood
decides what may run, how, and records it.

## 2. Who it is for

Small and medium engineering teams — the typical Indonesian startup — that
run PostgreSQL and don't want to buy or operate a heavy database-access
product. Must be self-hostable in five minutes (one Docker container).

It is also the first DITF tool (`../PLANNING.md`): the pattern it sets
(Vue + blessing-ui, readable layered Elixir, Channels for live updates) is
what `azoth` is later extracted from.

## 3. Scope

### v1

- PostgreSQL targets (any version supported by `libpg_query`).
- SQL editor in the browser; results as a table; CSV export.
- Read queries run immediately under guardrails (§5).
- Write queries run as a **dry run** first: executed inside a transaction,
  affected rows counted and previewed, then **rolled back**. Committing needs
  an explicit confirmation by the same person after seeing the dry run
  (§6.4).
- **Automatic backup of every row an `UPDATE` / `DELETE` changes** (CSV file,
  saved before commit), with generated restore SQL (§5.4).
- Per-query timeout and cancel button.
- No user management: access via Google Cloud IAP or gcloud SSH tunnel
  (IAM decides who gets in), per-database `read_only` / `read_write` mode
  from config, identity stamped into the audit log (§6).
- Append-only audit log with a live feed (§7).
- Runs on one GCP VM (systemd service); Docker image for local try-out;
  config via environment variables + `fumehood.toml`.

### Later

MySQL targets · column masking for personal data · saved queries ·
scheduled/recurring queries · Slack/Telegram notifications of commits.

### Not goals

Schema migration management (use your migration tool) · BI dashboards and
charts (that is `astrolabe`) · replacing a full SQL client (DBeaver, psql)
for developers' local databases.

## 4. Prior art

- **Bytebase** — database DevOps platform (Go): SQL review, change
  approval, schema migrations. Broad and powerful, open-core, heavier to run.
- **Archery**, **Yearning** — SQL audit/review platforms, mostly MySQL,
  popular in China.
- **Teleport / StrongDM** — access proxies: connection-level access and
  session recording; they don't understand or block individual statements.

fumehood's position: Postgres-first, statement-level safety using Postgres's
own parser, dry-run-then-commit as the default flow, fully open source,
running in one container. Smaller scope, easier to adopt.

## 5. Safety model

### 5.1 Parse, don't regex

Every submitted text is parsed with **`pg_query_ex`** (Electric SQL;
wraps `libpg_query`, the parser extracted from the PostgreSQL server). If
Postgres couldn't parse it, fumehood rejects it. Rules run on the AST, so
comments, odd casing, or quoting can't sneak a statement past them.

### 5.2 Statement rules (defaults, configurable per database)

Implemented in `Fumehood.Safety` (allowlist: anything not listed as allowed
is blocked).

| Statement | Default |
|---|---|
| `SELECT`, `EXPLAIN` (without `ANALYZE`), `SHOW` | allowed, read path |
| `EXPLAIN ANALYZE` of an allowed read | allowed, read path |
| `INSERT`, `UPDATE`, `DELETE` | allowed, write path (dry run → confirm) |
| `UPDATE` / `DELETE` without `WHERE` | **blocked** |
| user-written `RETURNING` on a write | **blocked** — fumehood adds its own to preview and back up rows |
| more than one statement in one submission | **blocked** (one statement at a time) |
| data-changing `WITH` clauses (`WITH … AS (INSERT/UPDATE/DELETE …)`) | **blocked** |
| `SELECT … INTO`, `SELECT … FOR UPDATE / FOR SHARE` | **blocked** |
| `EXPLAIN ANALYZE` of a write | **blocked** — it executes the write with no backup |
| `MERGE` | **blocked** — its changed rows can't be backed up before commit (§5.4) |
| `DROP`, `TRUNCATE`, `ALTER`, `CREATE`, `GRANT`, `REVOKE`, `COMMENT` (DDL / permissions) | **blocked** |
| `COPY`, `VACUUM`, `CLUSTER`, `REINDEX`, `LOCK` | **blocked** |
| transaction control (`BEGIN`, `COMMIT`, `SET`, `SAVEPOINT`…) typed by the user | **blocked** — fumehood owns the transaction |
| everything else (`DO`, `CALL`, `LISTEN`, `DISCARD`, …) | **blocked** |
| functions with side effects or that run SQL from a string (`pg_terminate_backend`, `pg_cancel_backend`, `pg_reload_conf`, `set_config`, `pg_notify`, `pg_read_file`, `query_to_xml`, `dblink*`, `lo_*`, `pg_advisory*` …), anywhere in the statement | **blocked** (deny-list) |

### 5.3 Always a transaction

Implemented in `Fumehood.Runner`. `pg_query_ex` only parses (no deparse),
so fumehood never regenerates SQL from the tree: it takes the statement's
exact text (the parser's offsets, minus a trailing `;`) and only **wraps or
appends** to it, always on new lines so a trailing `-- comment` can't
swallow what is added (`SELECT * FROM (\n<stmt>\n) … LIMIT n`,
`<stmt>\nRETURNING …`).

- **Read path:** `BEGIN READ ONLY` + `SET LOCAL statement_timeout` +
  `SET LOCAL lock_timeout`; results capped (auto `LIMIT 1000` when the
  query has none, with "load more"). Postgres itself refuses any
  write inside a read-only transaction — a second wall behind the parser.
- **Write path (dry run):** `BEGIN` → timeouts → primary-key check
  (`UPDATE` / `DELETE`) → run the statement with `RETURNING *` appended →
  count + preview the affected rows → row limit check → **`ROLLBACK`**.
  Nothing is kept.
- **Commit:** after the person who wrote it confirms (§6.4), the same
  statement runs again in a fresh transaction; if the affected row count differs from the
  dry run beyond a threshold, fumehood rolls back and asks again — the data
  changed in between.
- An upper limit on rows a single write may change (default 1000); above
  it the statement is blocked and must be split.

### 5.4 Backup before change

Every committed `UPDATE` or `DELETE` saves the rows it is about to change
**before** changing them: the rows are read and locked inside the change's
transaction, written to a backup file, and the transaction commits only
after the file is safely stored — **never a change without its backup**.

**How the "before" rows are captured:**

- fumehood builds a `SELECT * … FOR UPDATE` from the same statement's AST
  (same table, same `WHERE`, same `FROM` / `USING`), which reads and locks
  exactly the rows the change will touch; those rows are exported (below)
  before the change runs.
- If fumehood can't derive the before-rows safely for a statement, the
  **commit is refused** — no change without a backup.

**Stored as CSV files — decided.** Postgres writes the CSV itself
(`COPY (…) TO STDOUT WITH (FORMAT csv, HEADER)`), never fumehood's own
encoder: Postgres's CSV keeps `NULL` vs empty string, `jsonb`, arrays,
timestamps with time zone and `bytea` exactly, and reads back into the same
table with `COPY FROM`.

Commit sequence for an `UPDATE` / `DELETE`:

1. `BEGIN` → timeouts → lock the target rows (`SELECT … FOR UPDATE`, built
   from the statement's AST);
2. `COPY` exactly those rows out as CSV;
3. save `<audit_id>.csv` + `<audit_id>.json` (database, table, column names
   and types, primary key, statement, who, when) and wait until they are
   durably stored;
4. run the statement; check the row count against the dry run;
5. `COMMIT`. If step 3 or 4 fails → `ROLLBACK`: **never a change without a
   saved backup**. A file whose transaction then failed is marked
   "not applied" by the audit log (harmless).

Where the files go (`backup_dir` / `backup_bucket` in `fumehood.toml`):

- default on the VM (both modes): a local directory on the persistent disk,
  readable only by fumehood's system user;
- optional (needed on Cloud Run): a Google Cloud Storage bucket (encrypted
  at rest, access by IAM), `gs://<bucket>/<database>/<yyyy-mm-dd>/<audit_id>.csv`.

The files hold real production data (possibly personal data) outside the
database — the location must be restricted to fumehood and the people
allowed to restore, and retention (below) must be kept.

- Size is bounded: at most 1000 rows per write (§5.3).
- `INSERT` needs no before-image; fumehood records the new rows' primary keys
  so they can be undone.

**Restore:** for each commit, fumehood shows the backed-up rows and
**generates restore SQL** — load the CSV into a temporary table with
`COPY FROM`, then `INSERT` the deleted rows back, `UPDATE` the changed rows
to their old values by primary key, `DELETE` inserted rows.
The restore runs through fumehood like any write: dry run → confirm →
commit (and gets its own backup).

**Rules this adds:**

- `UPDATE` / `DELETE` on a table **without a primary key** is **blocked** —
  restore couldn't target the right rows.
- Retention **30 days** by default (per database in `fumehood.toml`);
  expired backup files are deleted by a job inside fumehood — no cron.

### 5.5 One process per query

Each running query lives in its own Elixir process, holding its own
connection and transaction. This is where Elixir earns its place:

- **timeout / cancel:** the process asks Postgres to cancel the query
  (`pg_cancel_backend` through Postgrex) and ends; the transaction rolls back;
- **a crash or a closed browser tab can't leave an open transaction:** the
  process holding it dies, the connection is dropped, Postgres rolls back;
- **live progress:** the process pushes its state (queued → running →
  rows counted → rolled back / committed) over a Channel to the browser;
- nothing else in the app is affected by one slow query.

## 6. Access control

**Decided: no accounts, no login screen.** fumehood gets each person's
identity from the way they reach it. v1 supports two modes (`FUMEHOOD_ACCESS`),
both built on Google Cloud:

| Mode | How people reach fumehood | Where identity comes from |
|---|---|---|
| `iap` | browser → Google Cloud IAP (HTTPS) → fumehood | IAP's signed JWT → Google account email |
| `ssh_tunnel` | `gcloud compute ssh … -L` through IAP TCP forwarding → `localhost` in the browser | the Linux user (OS Login) that owns the forwarded connection |

Cloudflare Access, oauth2-proxy and Tailscale are possible later modes.

### 6.1 Mode `iap` — Google Cloud IAP

- Every request carries IAP's identity. fumehood takes the user's **email**
  from it; that email is what the audit log records.
- **Verify, don't trust headers.** A plain header like
  `x-goog-authenticated-user-email` can be forged by anything that reaches
  fumehood without going through IAP. fumehood verifies the signed
  `x-goog-iap-jwt-assertion` JWT instead: signature against Google's public
  keys (cached, refreshed), `aud` equals the configured backend audience,
  `iss` is `https://cloud.google.com/iap`, not expired.
- On a VM: fumehood behind an HTTPS load balancer with IAP enabled (VM in an
  instance group as the backend, no public IP on the VM itself).

### 6.2 Mode `ssh_tunnel` — gcloud SSH port forwarding

How people use it:

```
gcloud compute ssh fumehood-vm --tunnel-through-iap -- -N -L 4000:localhost:4000
# then open http://localhost:4000
```

The VM needs no public IP; access is controlled by IAM
(`roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin` — not
`osAdminLogin`, so users get no sudo on the VM).

**Identity — who owns the connection.** With OS Login, every person SSHes in
as their own Linux user (derived from their Google account, e.g.
`jane_example_com`). When they forward a port, the connection into fumehood
is opened by *their* sshd process, so the kernel records their user id as
the owner of that socket. For each new connection fumehood:

1. takes the peer address/port of the incoming connection (always
   `127.0.0.1:<port>`);
2. finds the matching socket in `/proc/net/tcp` (and `tcp6`) and reads its
   owner **uid**;
3. resolves the uid to the OS Login username (`getent passwd`), which becomes
   the identity recorded in the audit log.

This can't be forged by a client: it comes from the kernel, not from
anything the browser sends. Limits and requirements:

- fumehood binds to `127.0.0.1` only in this mode (refuses other addresses
  at startup), so it is reachable only through SSH on that VM.
- fumehood must run **on the VM itself**, in the host network namespace and
  with host user lookup (OS Login users are resolved by an NSS module on the
  host, not in `/etc/passwd`): install the release as a systemd service.
  The Docker image is for `iap` mode.
- Anyone who can SSH to the VM is identified as themselves — including if
  they `curl` fumehood directly from their shell. `root` on the VM can
  impersonate any user; VM root access must be limited to admins (no
  `osAdminLogin` for normal users).
- Identity is per TCP connection; a browser's keep-alive and WebSocket
  connections are each checked when opened.
- Identity is the OS Login **username** (e.g. `jane_example_com`), not the
  email; it is what the audit log shows in this mode.
- **To prove first (milestone 2):** on a real GCP VM with OS Login, two
  different users forwarding at the same time are each resolved to their own
  username, and a connection whose owner can't be found gets `401`. The
  approach relies on sshd opening forwarded connections from the per-session
  process that runs as the logged-in user.

### 6.3 Common rules

- Requests without a valid identity get `401`; fumehood never falls back to
  anonymous access.
- WebSocket (Channels) connections are checked the same way when the socket
  connects.
- Local development: `FUMEHOOD_DEV_USER=someone@example.com` sets a fixed
  identity; refused at startup when running in production mode.

### 6.4 Permissions — no user management in v1

**Decided: fumehood keeps no users, roles or grants.** Who may use it is
decided entirely by Google Cloud IAM; the identity from §6.1/§6.2 is used
only to stamp the audit log.

- **Who gets in:** whoever IAM lets through — `roles/iap.httpsResourceAccessor`
  on the IAP backend (`iap` mode), or `roles/iap.tunnelResourceAccessor` +
  `roles/compute.osLogin` on the VM (`ssh_tunnel` mode). Adding or removing
  a person is an IAM change, not a fumehood change.
- **What they may do:** set **per database** in config, the same for everyone
  who gets in:
  - `read_only` — read path only; writes are rejected before parsing rules;
  - `read_write` — reads + write dry runs + commit.
- **Different permissions for different people = separate instances.** E.g.
  one fumehood with every production database `read_only`, reachable by the
  whole engineering group; a second with `read_write`, reachable only by a
  small on-call group. IAM decides who reaches which.
- **No approval flow in the app — decided.** Approving a change (ticket,
  chat, review) happens outside fumehood, in the team's own process.
  Inside fumehood the person who wrote the statement reviews the dry run
  (row count + preview) and confirms the commit; that confirmation is a
  safety check, not an approval. The audit log records it.
- **Later (if teams ask):** per-user grants inside fumehood.

### 6.5 Databases and credentials

- Target databases are defined in a **config file** mounted into the
  container / placed on the VM (`fumehood.toml`), not registered through a
  UI — no admin screens in v1:

  ```toml
  [databases.orders_prod]
  label    = "Orders (production)"
  mode     = "read_only"          # or "read_write"
  url_env  = "ORDERS_PROD_URL"    # connection string read from this env var
  max_rows = 1000                 # optional overrides of §5 defaults
  ```

- **Credentials never live in fumehood's store:** connection strings come
  from environment variables, filled from a root-only env file on the VM
  (or Google Secret Manager on Cloud Run, later). Nothing to encrypt at rest, nothing
  shown in the UI.
- Recommend giving fumehood a Postgres role with only the privileges it
  needs — for `read_only` databases, a role with `SELECT` only, so Postgres
  enforces it a third time (parser → read-only transaction → role).

## 7. Audit

Append-only record of every action: who, when, which database, the SQL text,
path (read / dry run / commit), rows affected, duration, outcome (ok /
blocked + rule / error / cancelled / timed out), and for commits the dry-run
count the person confirmed and the backup id (§5.4).

- Live feed in the UI over a Channel — anyone with access sees activity as it happens.
- Export (CSV / JSON); retention configurable.
- Result data itself is **not** stored by default (it may hold personal
  data); only counts.

## 8. Architecture

```
Browser: Vue 3 + blessing-ui (SPA)
   │
Google Cloud IAP (HTTPS)  or  gcloud SSH tunnel (IAP TCP forwarding)
   │  JSON over HTTP            │  Phoenix Channels (WebSocket)
   ▼                            ▼
Identity check (IAP JWT → email  |  socket owner uid → OS Login user)
   ▼                            ▼
Router ─► Controllers      QueryChannel / AuditChannel
             │                  │
             ▼                  ▼
          Services  ──►  QueryRunner (one process per query,
             │            under a DynamicSupervisor)
             ▼                  │
        Repositories            ▼
             │           Target Postgres (Postgrex)
             ▼
   fumehood's own store (audit log only)
```

Layers are plain modules a Go developer can map directly:

| Go habit | fumehood |
|---|---|
| `http.Handler` + chi routes | router → controller functions (`conn, params`) |
| service struct | `Fumehood.Services.*` — business rules, no HTTP |
| repository | `Fumehood.Repos.*` — Ecto queries only |
| goroutine + context cancel | `QueryRunner` process + cancel message |

**Decided** — HTTP layer: **Phoenix, used minimally** (router, controllers,
Channels; no LiveView, no generators' context magic, no HTML templates).
Channels are the reason: they're the most mature WebSocket pub/sub on the
BEAM and one of the things fumehood should show off. The alternative —
Plug + Bandit + a raw WebSocket library — means writing channel/topic
handling ourselves.

**Decided** — own store: **SQLite** (`ecto_sqlite3`) by default, so the Docker
image runs with a single volume and no extra database; Postgres as an option
for teams that want it.

## 9. Deployment

**Decided: VM first.** v1 targets one Compute Engine VM for both access
modes; Cloud Run is an optional later target.

- **Build:** one Elixir release with the built Vue SPA served from
  `priv/static` — the same build is installed on the VM and packed into the
  Docker image.
- **On the VM (v1):** the release as a systemd service; SQLite file and
  backup directory on the VM's persistent disk; connection strings in a
  root-only env file; no public IP.
  - `ssh_tunnel`: people use `gcloud compute ssh … -L` (§6.2).
  - `iap`: an HTTPS load balancer with IAP in front of the VM (§6.1).
- **Config:** `FUMEHOOD_SECRET_KEY`, `FUMEHOOD_ACCESS=iap|ssh_tunnel` (+ IAP
  audience for `iap`), port, `fumehood.toml` (databases, `backup_dir`), one
  env var per database connection string.
- **Try-out:** the Docker image —
  `docker run -p 4000:4000 -v fumehood:/data -v ./fumehood.toml:/etc/fumehood.toml
  -e FUMEHOOD_DEV_USER=me@x.com -e ORDERS_PROD_URL=… …` → query. Five
  minutes, local only.
- **Cloud Run (optional, later):** needs the Postgres store instead of SQLite
  (Cloud Run has no persistent disk; SQLite on a mounted bucket is
  unreliable) and a GCS bucket for backups; `iap` mode only. GKE with a
  persistent volume works like the VM.
- Docs include the VM setup for both modes step by step.

## 10. Milestones

1. **Core safety, no UI:** parser rules (§5.2) + read path + write dry run
   + backup-before-change and restore SQL (§5.4) against a test Postgres
   (16 and 18), with tests for every rule (including tricky
   inputs: comments, CTEs with writes, `SELECT` calling side-effect
   functions, multiple statements).
2. **API + minimal UI:** identity for both modes (IAP JWT, SSH-tunnel socket
   owner) + dev user, databases from `fumehood.toml`, editor, results table,
   dry run → confirm → commit.
3. **Live + audit:** QueryRunner processes, cancel/timeout, Channels for
   progress and the audit feed.
4. **Hardening:** per-database `read_only` / `read_write` enforcement
   tests, Secret Manager / env-file setup docs, two-instance example.
5. **Packaging:** VM install (release + systemd unit + setup script for both
   modes), Docker image for try-out, docs (English + Bahasa Indonesia),
   first release.

## 11. Decisions

Decided 2026-09-27:

1. ✅ Statement rules and defaults (§5.2) — accepted as the starting set.
2. ✅ Limits — auto `LIMIT 1000` on reads, max 1000 rows per write.
3. ✅ HTTP layer — minimal Phoenix (router, controllers, Channels only).
4. ✅ Own store — SQLite by default.
5. ✅ Accounts — none. Two access modes (§6): Google Cloud IAP (verified
   JWT → email) and gcloud SSH tunnel (socket owner → OS Login user).
   Cloudflare Access / oauth2-proxy / Tailscale later.
   No user management: IAM decides who gets in; per-database mode from
   config; databases and credentials from `fumehood.toml` + env (§6.4, §6.5).
6. ✅ Approval — none in the app; it happens outside fumehood. The author
   confirms their own write after the dry run (safety check only).
7. ✅ Frontend — Vue SPA built into the same image as the Elixir release.
8. ✅ Backup every row an `UPDATE` / `DELETE` changes, saved before the
   commit, with generated restore SQL (§5.4).

9. ✅ Backup storage — CSV files written by Postgres `COPY`, plus a JSON
   metadata file; local directory (VM) or GCS bucket; saved before commit.
10. ✅ `UPDATE` / `DELETE` on tables without a primary key — blocked.
11. ✅ Backup retention — 30 days by default, per database.
12. ✅ Hosting — VM first (both modes, SQLite + local backups on the VM's
    disk); Cloud Run optional later with the Postgres store + a GCS bucket.

No open decisions left for v1.
