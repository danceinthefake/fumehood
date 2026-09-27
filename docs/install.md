# Installing fumehood

Two ways to run fumehood:

- **Try it** on your own machine with the Docker image, in five minutes.
- **Run it for your team** on a Google Compute Engine VM, reached through an
  SSH tunnel or through Google Cloud IAP.

Before a real install, prepare the Postgres roles and secrets:
[setup.md](setup.md).

## Try it with Docker

Build the image (from a checkout of this repository):

```sh
docker build -t fumehood .
```

Write a `fumehood.toml` that points at a database you can reach:

```toml
backup_dir = "/data/backups"

[databases.local]
label   = "My local database"
mode    = "read_write"
url_env = "LOCAL_URL"
```

Run it, reachable from your machine only:

```sh
docker run --rm -p 127.0.0.1:4000:4000 \
  --add-host host.docker.internal:host-gateway \
  -v fumehood-data:/data \
  -v ./fumehood.toml:/etc/fumehood/fumehood.toml:ro \
  -e FUMEHOOD_ACCESS=dev -e FUMEHOOD_DEV_USER=you@example.com \
  -e SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 -w0)" \
  -e LOCAL_URL=postgres://user:password@host.docker.internal:5432/mydb \
  fumehood
```

Open <http://localhost:4000>.

`FUMEHOOD_ACCESS=dev` means **no identity check**: everyone who reaches the
port acts as `FUMEHOOD_DEV_USER`. Use it only on your own machine, never on a
server.

## Run it on a VM

### What you need

- A Compute Engine VM running Debian 12+ or Ubuntu 24.04+, **with no public
  IP**, on a network that can reach your Postgres databases.
- OS Login enabled on the VM (`enable-oslogin=TRUE` metadata), so everyone
  signs in as their own Linux user.
- Only if you build the release yourself: Docker on the machine where you
  build it (not on the VM).

### 1. Get the release

Download `fumehood-0.1.3.tar.gz` and its `.sha256` from the
[Releases page](https://github.com/danceinthefake/fumehood/releases) into
`dist/`, and check it:

```sh
cd dist && sha256sum -c fumehood-0.1.3.tar.gz.sha256 && cd ..
```

Or build it from source:

```sh
scripts/build-release.sh    # → dist/fumehood-0.1.3.tar.gz
```

### 2. Install it on the VM

```sh
gcloud compute scp dist/fumehood-0.1.3.tar.gz fumehood:~ --tunnel-through-iap
gcloud compute ssh fumehood --tunnel-through-iap

# on the VM:
mkdir fumehood && tar -xzf fumehood-0.1.3.tar.gz -C fumehood
sudo fumehood/install.sh ssh_tunnel     # or: iap
```

`install.sh` creates:

| Path                                   | What                                          |
|----------------------------------------|-----------------------------------------------|
| `/opt/fumehood` → `/opt/fumehood-0.1.3`| the release (owned by root)                   |
| `/etc/fumehood/fumehood.toml`          | your databases (`0640 root:fumehood`)         |
| `/etc/fumehood/fumehood.env`           | secrets and settings (`0600 root`)            |
| `/var/lib/fumehood/`                   | audit log and backups (`0700 fumehood`)       |
| `fumehood.service`                     | the systemd unit, enabled                     |

### 3. Configure and start

Edit `/etc/fumehood/fumehood.toml` (your databases) and
`/etc/fumehood/fumehood.env` (their connection strings; see
[setup.md](setup.md) for the Postgres roles), then:

```sh
sudo systemctl start fumehood
sudo journalctl -u fumehood -f
curl localhost:4000/health    # → ok
```

A mistake in the config stops startup and the journal lists every problem.

### 4a. Mode `ssh_tunnel`

fumehood listens on `127.0.0.1:4000` only. People reach it through an SSH
tunnel, and fumehood knows who they are from the Linux user that owns the
tunnel's connection.

Allow SSH through IAP (once per network):

```sh
gcloud compute firewall-rules create allow-iap-ssh \
  --network=NETWORK --direction=INGRESS --action=allow \
  --rules=tcp:22 --source-ranges=35.235.240.0/20
```

Give each person (or better, a group) access:

```sh
gcloud projects add-iam-policy-binding PROJECT \
  --member=group:engineering@example.com --role=roles/iap.tunnelResourceAccessor
gcloud compute instances add-iam-policy-binding fumehood --zone=ZONE \
  --member=group:engineering@example.com --role=roles/compute.osLogin
```

Use `roles/compute.osLogin`, not `osAdminLogin`: root on the VM could act as
anyone.

Each person then runs:

```sh
gcloud compute ssh fumehood --tunnel-through-iap -- -N -L 4000:localhost:4000
```

and opens <http://localhost:4000>. The audit log shows their OS Login
username (e.g. `jane_example_com`).

### 4b. Mode `iap`

fumehood sits behind an HTTPS load balancer with Identity-Aware Proxy, and
checks the signed IAP header on every request.

1. Put the VM in an unmanaged instance group with a named port
   `http:4000`.
2. Create a health check on port 4000, path `/health`.
3. Create a backend service (HTTP) with that instance group and health
   check, then an external HTTPS load balancer with a Google-managed
   certificate for your host name.
4. Allow the load balancer and health checks to reach the VM:

   ```sh
   gcloud compute firewall-rules create allow-lb-fumehood \
     --network=NETWORK --direction=INGRESS --action=allow \
     --rules=tcp:4000 --source-ranges=130.211.0.0/22,35.191.0.0/16
   ```

5. Turn on IAP for the backend service and grant access:

   ```sh
   gcloud iap web enable --resource-type=backend-services --service=fumehood
   gcloud iap web add-iam-policy-binding --resource-type=backend-services \
     --service=fumehood --member=group:engineering@example.com \
     --role=roles/iap.httpsResourceAccessor
   ```

6. In `/etc/fumehood/fumehood.env`, set:

   ```sh
   PHX_HOST=fumehood.example.com
   FUMEHOOD_IAP_AUDIENCE=/projects/PROJECT_NUMBER/global/backendServices/SERVICE_ID
   ```

   `SERVICE_ID` is the numeric id:
   `gcloud compute backend-services describe fumehood --global --format='value(id)'`.
   Then `sudo systemctl restart fumehood`.

The audit log shows each person's Google account email.

The Docker image also works for `iap` mode on any host behind the same load
balancer; `ssh_tunnel` mode needs the systemd install, because it reads
socket owners and OS Login users from the VM itself.

## Upgrading

Build the new tarball and run its `install.sh` the same way. It installs the
new release next to the old one, points `/opt/fumehood` at it, keeps your
config and data, and restarts the service. To roll back, run the old
release's `install.sh` again.

## Day to day

- Logs: `journalctl -u fumehood`.
- Audit log: `/var/lib/fumehood/fumehood.db` (SQLite, append-only), also in
  the UI's Audit tab.
- Backups: `/var/lib/fumehood/backups/<database>/`, removed after
  `backup_retention_days` (30 by default). Include `/var/lib/fumehood` in the
  VM's disk snapshots.
- Remove: `systemctl disable --now fumehood`, then delete
  `/etc/systemd/system/fumehood.service`, `/opt/fumehood*`, `/etc/fumehood`
  and (after keeping what you need) `/var/lib/fumehood`.
