# Setting up fumehood

This covers what to prepare before installing fumehood: the Postgres roles it
connects as, where its secrets live, and how to give different people
different permissions. The install itself: [install.md](install.md).

## 1. Postgres roles

fumehood checks every statement itself, but the role it connects as is the
last wall. Give each target database a role with only what its mode needs.
Never connect as the table owner or a superuser: an owner can run DDL, and
fumehood's checks would then be the only thing in the way.

### `read_only` databases

```sql
CREATE ROLE fumehood_ro LOGIN PASSWORD '…';
GRANT CONNECT ON DATABASE orders TO fumehood_ro;
GRANT USAGE ON SCHEMA public TO fumehood_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fumehood_ro;
-- tables created later (run as the role that creates them):
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fumehood_ro;
```

A write is then refused three times over: by fumehood's rules, by the
read-only transaction, and by Postgres itself.

### `read_write` databases

```sql
CREATE ROLE fumehood_rw LOGIN PASSWORD '…';
GRANT CONNECT, TEMPORARY ON DATABASE orders TO fumehood_rw;
GRANT USAGE ON SCHEMA public TO fumehood_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fumehood_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fumehood_rw;
-- tables and sequences created later:
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fumehood_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO fumehood_rw;
```

- `SELECT` is needed for writes too: the backup reads the rows before they
  change.
- `TEMPORARY` is needed for restore, which loads the backup into a temporary
  table. Postgres grants it to `PUBLIC` by default; grant it explicitly in
  case your databases revoke that.
- No `CREATE`, no `TRUNCATE`, no ownership: fumehood blocks DDL, and the role
  can't run it either.
- Backups cover the target table only. Triggers and cascading foreign keys
  can change other tables too; the dry run warns about them, and those other
  changes can't be restored. For the same reason, a change can't call your
  own functions unless they're declared `STABLE` or `IMMUTABLE` (Postgres's
  built-in functions are fine).

These exact grants are covered by a test (`test/fumehood_web/enforcement_test.exs`),
which runs a dry run, a commit with backup, and a restore as a role that has
only them.

Other schemas: repeat the `USAGE` / table / sequence grants per schema.

## 2. Secrets

fumehood keeps no credentials in its own store or in `fumehood.toml`. Each
database names an environment variable that holds its connection string.

### Env file (default)

`/etc/fumehood/fumehood.env`, owned by root, mode `0600`. `install.sh`
creates it with a generated `SECRET_KEY_BASE`; add one line per database:

```sh
FUMEHOOD_ACCESS=ssh_tunnel
SECRET_KEY_BASE=…
PORT=4000
ORDERS_PROD_URL=postgres://fumehood_ro:…@10.0.0.5/orders
```

The systemd unit loads it with `EnvironmentFile=/etc/fumehood/fumehood.env`;
systemd reads the file as root before dropping to the service user, so the
service user never needs to read it.

### Google Secret Manager (optional)

Keep the connection strings in Secret Manager and write them to a second env
file at each start. Add a drop-in with `sudo systemctl edit fumehood`:

```ini
[Service]
ExecStartPre=+/bin/sh -c 'umask 077; { \
  echo "SECRET_KEY_BASE=$(gcloud secrets versions access latest --secret=fumehood-secret-key-base)"; \
  echo "ORDERS_PROD_URL=$(gcloud secrets versions access latest --secret=orders-prod-url)"; \
} > /run/fumehood/secrets.env'
EnvironmentFile=-/run/fumehood/secrets.env
```

Remove those lines from `/etc/fumehood/fumehood.env`; values in the second
file win.

The VM's service account needs `roles/secretmanager.secretAccessor` on those
secrets only. `/run` is memory-backed, so the values never touch the disk.

### Files fumehood writes

- The audit log (`DATABASE_PATH`) and `backup_dir` hold data from production
  tables. The unit keeps them in `/var/lib/fumehood`, owner-only (`0700`
  directories, `0600` files). A `backup_dir` elsewhere must be owned by the
  `fumehood` user and added to the unit with `ReadWritePaths=`.
- Backups expire after `backup_retention_days` (30 by default).

## 3. Different permissions for different people

fumehood has no users or grants of its own: `mode` in `fumehood.toml` applies
to everyone who gets in, and Google Cloud IAM decides who gets in. To give
some people more, run **two instances**:

| Instance     | Databases    | Who can reach it              |
|--------------|--------------|-------------------------------|
| `fumehood`   | `read_only`  | the whole engineering group   |
| `fumehood-rw`| `read_write` | a small on-call group         |

`fumehood.toml` for the read-only instance:

```toml
backup_dir = "/var/lib/fumehood/backups"

[databases.orders_prod]
label   = "Orders (production)"
mode    = "read_only"
url_env = "ORDERS_PROD_URL"          # connects as fumehood_ro
```

`fumehood.toml` for the read-write instance:

```toml
backup_dir = "/var/lib/fumehood/backups"

[databases.orders_prod]
label   = "Orders (production, writes)"
mode    = "read_write"
url_env = "ORDERS_PROD_URL"          # connects as fumehood_rw
max_rows = 100                       # optional: stricter than the default 1000
```

Give each instance its own Postgres role (section 1): the read-only instance
must not hold `fumehood_rw` credentials.

### With `ssh_tunnel`

One VM per instance. Grant each group access to its VM only:

```sh
# everyone: the read-only VM
gcloud compute instances add-iam-policy-binding fumehood \
  --member=group:engineering@example.com --role=roles/compute.osLogin
# on-call only: the read-write VM
gcloud compute instances add-iam-policy-binding fumehood-rw \
  --member=group:oncall@example.com --role=roles/compute.osLogin
```

Both groups also need `roles/iap.tunnelResourceAccessor` (limited to their
VM with an IAM condition, or the project's firewall rule for IAP TCP
forwarding).

### With `iap`

One backend service per instance behind the load balancer, each with its own
IAP audience (`FUMEHOOD_IAP_AUDIENCE`) and its own
`roles/iap.httpsResourceAccessor` binding:

```sh
gcloud iap web add-iam-policy-binding --resource-type=backend-services \
  --service=fumehood --member=group:engineering@example.com \
  --role=roles/iap.httpsResourceAccessor
gcloud iap web add-iam-policy-binding --resource-type=backend-services \
  --service=fumehood-rw --member=group:oncall@example.com \
  --role=roles/iap.httpsResourceAccessor
```

Adding or removing a person is an IAM change; fumehood needs no restart.

## 4. Environment variables

| Variable                | Required         | Meaning |
|-------------------------|------------------|---------|
| `FUMEHOOD_ACCESS`       | yes (prod)       | `iap` or `ssh_tunnel`; `dev` only for a local try-out |
| `FUMEHOOD_IAP_AUDIENCE` | with `iap`       | `/projects/NUMBER/global/backendServices/ID` |
| `FUMEHOOD_CONFIG`       | no               | path to `fumehood.toml` (default `/etc/fumehood/fumehood.toml`) |
| `DATABASE_PATH`         | set by the unit  | SQLite file for the audit log (`/var/lib/fumehood/fumehood.db`) |
| `SECRET_KEY_BASE`       | yes (prod)       | random, 48+ bytes; `install.sh` generates it |
| `PHX_HOST`              | with `iap`       | public host name; also the allowed WebSocket origin |
| `PHX_SERVER`            | set by the unit  | `true` to start the HTTP server |
| `PORT`                  | no               | HTTP port (default 4000); `ssh_tunnel` binds 127.0.0.1 only |
| `POOL_SIZE`             | no               | SQLite pool size (default 5) |
| `FUMEHOOD_DEV_USER`     | no               | the fixed identity in `dev` mode (default `dev@localhost`) |
| one per database        | yes              | the connection string named by `url_env` |
