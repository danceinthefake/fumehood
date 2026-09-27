# Menyiapkan fumehood

[English](setup.md) · Bahasa Indonesia

Dokumen ini membahas apa yang perlu disiapkan sebelum memasang fumehood: role
Postgres yang dipakai fumehood untuk terhubung, tempat menyimpan rahasia
(*secret*), dan cara memberi izin yang berbeda untuk orang yang berbeda.
Cara memasangnya: [install.id.md](install.id.md).

## 1. Role Postgres

fumehood memeriksa sendiri setiap perintah SQL, tetapi role yang dipakainya
untuk terhubung adalah benteng terakhir. Beri setiap database tujuan role
yang hanya punya hak sesuai mode-nya. Jangan pernah terhubung sebagai pemilik
tabel atau superuser: pemilik tabel bisa menjalankan DDL, sehingga
pemeriksaan fumehood menjadi satu-satunya penghalang.

### Database `read_only`

```sql
CREATE ROLE fumehood_ro LOGIN PASSWORD '…';
GRANT CONNECT ON DATABASE orders TO fumehood_ro;
GRANT USAGE ON SCHEMA public TO fumehood_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fumehood_ro;
-- tabel yang dibuat nanti (jalankan sebagai role yang membuat tabel):
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fumehood_ro;
```

Dengan begitu, perintah tulis ditolak tiga lapis: oleh aturan fumehood, oleh
transaksi read-only, dan oleh Postgres sendiri.

### Database `read_write`

```sql
CREATE ROLE fumehood_rw LOGIN PASSWORD '…';
GRANT CONNECT, TEMPORARY ON DATABASE orders TO fumehood_rw;
GRANT USAGE ON SCHEMA public TO fumehood_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fumehood_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fumehood_rw;
-- tabel dan sequence yang dibuat nanti:
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fumehood_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO fumehood_rw;
```

- `SELECT` tetap diperlukan untuk perintah tulis: backup membaca baris-baris
  yang akan berubah sebelum perubahan terjadi.
- `TEMPORARY` diperlukan untuk restore, yang memuat backup ke tabel
  sementara. Secara bawaan Postgres memberikannya ke `PUBLIC`; berikan secara
  eksplisit untuk berjaga-jaga kalau database Anda mencabutnya.
- Tanpa `CREATE`, tanpa `TRUNCATE`, bukan pemilik tabel: fumehood memblokir
  DDL, dan role-nya pun tidak bisa menjalankannya.
- Backup hanya mencakup tabel tujuan. Trigger dan foreign key yang cascade
  bisa ikut mengubah tabel lain; dry run memberi peringatan soal keduanya,
  dan perubahan di tabel lain itu tidak bisa di-restore. Karena alasan yang
  sama, perubahan tidak boleh memanggil function buatan sendiri kecuali
  function itu dideklarasikan `STABLE` atau `IMMUTABLE` (function bawaan
  Postgres boleh).

Hak akses persis seperti di atas diuji (`test/fumehood_web/enforcement_test.exs`):
dry run, commit dengan backup, dan restore dijalankan sebagai role yang hanya
punya hak-hak tersebut.

Schema lain: ulangi `GRANT` untuk `USAGE`, tabel, dan sequence di setiap
schema.

## 2. Rahasia

fumehood tidak menyimpan kredensial di penyimpanannya sendiri maupun di
`fumehood.toml`. Setiap database menyebut nama variabel lingkungan
(*environment variable*) yang berisi connection string-nya.

### File env (bawaan)

`/etc/fumehood/fumehood.env`, milik root, mode `0600`. `install.sh`
membuatnya dengan `SECRET_KEY_BASE` acak; tambahkan satu baris per database:

```sh
FUMEHOOD_ACCESS=ssh_tunnel
SECRET_KEY_BASE=…
PORT=4000
ORDERS_PROD_URL=postgres://fumehood_ro:…@10.0.0.5/orders
```

Unit systemd memuatnya lewat `EnvironmentFile=/etc/fumehood/fumehood.env`;
systemd membaca file ini sebagai root sebelum berpindah ke user layanan,
jadi user layanan tidak perlu bisa membacanya.

### Google Secret Manager (opsional)

Simpan connection string di Secret Manager, lalu tulis ke file env kedua
setiap kali layanan dijalankan. Tambahkan *drop-in* dengan
`sudo systemctl edit fumehood`:

```ini
[Service]
ExecStartPre=+/bin/sh -c 'umask 077; { \
  echo "SECRET_KEY_BASE=$(gcloud secrets versions access latest --secret=fumehood-secret-key-base)"; \
  echo "ORDERS_PROD_URL=$(gcloud secrets versions access latest --secret=orders-prod-url)"; \
} > /run/fumehood/secrets.env'
EnvironmentFile=-/run/fumehood/secrets.env
```

Hapus baris-baris tersebut dari `/etc/fumehood/fumehood.env`; nilai di file
kedua yang dipakai.

Service account VM hanya perlu `roles/secretmanager.secretAccessor` pada
secret-secret tersebut. `/run` ada di memori, jadi nilainya tidak pernah
tertulis ke disk.

### File yang ditulis fumehood

- Audit log (`DATABASE_PATH`) dan `backup_dir` berisi data dari tabel
  produksi. Unit systemd menyimpannya di `/var/lib/fumehood`, hanya bisa
  diakses pemiliknya (direktori `0700`, file `0600`). Kalau `backup_dir` di
  tempat lain, direktorinya harus milik user `fumehood` dan ditambahkan ke
  unit dengan `ReadWritePaths=`.
- Backup dihapus setelah `backup_retention_days` (bawaan 30 hari).

## 3. Izin berbeda untuk orang berbeda

fumehood tidak punya user atau hak akses sendiri: `mode` di `fumehood.toml`
berlaku untuk semua orang yang bisa masuk, dan Google Cloud IAM yang
menentukan siapa yang bisa masuk. Untuk memberi sebagian orang akses lebih,
jalankan **dua instance**:

| Instance     | Database     | Siapa yang bisa mengakses       |
|--------------|--------------|---------------------------------|
| `fumehood`   | `read_only`  | seluruh tim engineering         |
| `fumehood-rw`| `read_write` | grup on-call yang kecil         |

`fumehood.toml` untuk instance read-only:

```toml
backup_dir = "/var/lib/fumehood/backups"

[databases.orders_prod]
label   = "Orders (production)"
mode    = "read_only"
url_env = "ORDERS_PROD_URL"          # terhubung sebagai fumehood_ro
```

`fumehood.toml` untuk instance read-write:

```toml
backup_dir = "/var/lib/fumehood/backups"

[databases.orders_prod]
label   = "Orders (production, writes)"
mode    = "read_write"
url_env = "ORDERS_PROD_URL"          # terhubung sebagai fumehood_rw
max_rows = 100                       # opsional: lebih ketat dari bawaan 1000
```

Beri setiap instance role Postgres-nya sendiri (bagian 1): instance
read-only tidak boleh memegang kredensial `fumehood_rw`.

### Dengan `ssh_tunnel`

Satu VM per instance. Beri setiap grup akses ke VM-nya saja:

```sh
# semua orang: VM read-only
gcloud compute instances add-iam-policy-binding fumehood \
  --member=group:engineering@example.com --role=roles/compute.osLogin
# hanya on-call: VM read-write
gcloud compute instances add-iam-policy-binding fumehood-rw \
  --member=group:oncall@example.com --role=roles/compute.osLogin
```

Kedua grup juga perlu `roles/iap.tunnelResourceAccessor` (dibatasi ke VM
masing-masing dengan IAM condition, atau lewat firewall rule proyek untuk IAP
TCP forwarding).

### Dengan `iap`

Satu backend service per instance di belakang load balancer, masing-masing
dengan IAP audience sendiri (`FUMEHOOD_IAP_AUDIENCE`) dan binding
`roles/iap.httpsResourceAccessor` sendiri:

```sh
gcloud iap web add-iam-policy-binding --resource-type=backend-services \
  --service=fumehood --member=group:engineering@example.com \
  --role=roles/iap.httpsResourceAccessor
gcloud iap web add-iam-policy-binding --resource-type=backend-services \
  --service=fumehood-rw --member=group:oncall@example.com \
  --role=roles/iap.httpsResourceAccessor
```

Menambah atau mencabut akses seseorang cukup lewat IAM; fumehood tidak perlu
di-restart.

## 4. Variabel lingkungan

| Variabel                | Wajib              | Arti |
|-------------------------|--------------------|------|
| `FUMEHOOD_ACCESS`       | ya (prod)          | `iap` atau `ssh_tunnel`; `dev` hanya untuk mencoba di mesin sendiri |
| `FUMEHOOD_IAP_AUDIENCE` | dengan `iap`       | `/projects/NUMBER/global/backendServices/ID` |
| `FUMEHOOD_CONFIG`       | tidak              | path ke `fumehood.toml` (bawaan `/etc/fumehood/fumehood.toml`) |
| `DATABASE_PATH`         | diatur oleh unit   | file SQLite untuk audit log (`/var/lib/fumehood/fumehood.db`) |
| `SECRET_KEY_BASE`       | ya (prod)          | acak, 48+ byte; dibuat oleh `install.sh` |
| `PHX_HOST`              | dengan `iap`       | nama host publik; juga origin WebSocket yang diizinkan |
| `PHX_SERVER`            | diatur oleh unit   | `true` untuk menjalankan server HTTP |
| `PORT`                  | tidak              | port HTTP (bawaan 4000); `ssh_tunnel` hanya mendengarkan di 127.0.0.1 |
| `POOL_SIZE`             | tidak              | ukuran pool SQLite (bawaan 5) |
| `FUMEHOOD_DEV_USER`     | tidak              | identitas tetap di mode `dev` (bawaan `dev@localhost`) |
| satu per database       | ya                 | connection string yang disebut oleh `url_env` |
