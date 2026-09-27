# Memasang fumehood

[English](install.md) · Bahasa Indonesia

Ada dua cara menjalankan fumehood:

- **Mencoba** di mesin sendiri dengan image Docker, dalam lima menit.
- **Menjalankan untuk tim** di VM Google Compute Engine, diakses lewat SSH
  tunnel atau lewat Google Cloud IAP.

Sebelum pemasangan sungguhan, siapkan dulu role Postgres dan rahasianya:
[setup.id.md](setup.id.md).

## Mencoba dengan Docker

Build image-nya (dari checkout repositori ini):

```sh
docker build -t fumehood .
```

Tulis `fumehood.toml` yang menunjuk ke database yang bisa Anda akses:

```toml
backup_dir = "/data/backups"

[databases.local]
label   = "Database lokal saya"
mode    = "read_write"
url_env = "LOCAL_URL"
```

Jalankan, hanya bisa diakses dari mesin Anda sendiri:

```sh
docker run --rm -p 127.0.0.1:4000:4000 \
  --add-host host.docker.internal:host-gateway \
  -v fumehood-data:/data \
  -v ./fumehood.toml:/etc/fumehood/fumehood.toml:ro \
  -e FUMEHOOD_ACCESS=dev -e FUMEHOOD_DEV_USER=anda@example.com \
  -e SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 -w0)" \
  -e LOCAL_URL=postgres://user:password@host.docker.internal:5432/mydb \
  fumehood
```

Buka <http://localhost:4000>.

`FUMEHOOD_ACCESS=dev` berarti **tanpa pemeriksaan identitas**: siapa pun yang
bisa mengakses port itu bertindak sebagai `FUMEHOOD_DEV_USER`. Pakai hanya di
mesin sendiri, jangan pernah di server.

## Menjalankan di VM

### Yang dibutuhkan

- VM Compute Engine dengan Debian 12+ atau Ubuntu 24.04+, **tanpa IP
  publik**, di jaringan yang bisa menjangkau database Postgres Anda.
- OS Login aktif di VM (metadata `enable-oslogin=TRUE`), supaya setiap orang
  masuk sebagai user Linux-nya sendiri.
- Hanya kalau mem-build release sendiri: Docker di mesin tempat Anda
  mem-build-nya (bukan di VM).

### 1. Ambil release

Unduh `fumehood-0.1.2.tar.gz` beserta `.sha256`-nya dari
[halaman Releases](https://github.com/danceinthefake/fumehood/releases) ke
`dist/`, lalu periksa:

```sh
cd dist && sha256sum -c fumehood-0.1.2.tar.gz.sha256 && cd ..
```

Atau build dari source:

```sh
scripts/build-release.sh    # → dist/fumehood-0.1.2.tar.gz
```

### 2. Pasang di VM

```sh
gcloud compute scp dist/fumehood-0.1.2.tar.gz fumehood:~ --tunnel-through-iap
gcloud compute ssh fumehood --tunnel-through-iap

# di VM:
mkdir fumehood && tar -xzf fumehood-0.1.2.tar.gz -C fumehood
sudo fumehood/install.sh ssh_tunnel     # atau: iap
```

`install.sh` membuat:

| Path                                   | Isi                                              |
|----------------------------------------|--------------------------------------------------|
| `/opt/fumehood` → `/opt/fumehood-0.1.2`| release-nya (milik root)                         |
| `/etc/fumehood/fumehood.toml`          | daftar database (`0640 root:fumehood`)           |
| `/etc/fumehood/fumehood.env`           | rahasia dan pengaturan (`0600 root`)             |
| `/var/lib/fumehood/`                   | audit log dan backup (`0700 fumehood`)           |
| `fumehood.service`                     | unit systemd, sudah di-enable                    |

### 3. Atur dan jalankan

Ubah `/etc/fumehood/fumehood.toml` (daftar database) dan
`/etc/fumehood/fumehood.env` (connection string-nya; lihat
[setup.id.md](setup.id.md) untuk role Postgres), lalu:

```sh
sudo systemctl start fumehood
sudo journalctl -u fumehood -f
curl localhost:4000/health    # → ok
```

Kalau ada kesalahan di konfigurasi, fumehood tidak mau jalan dan journal
menampilkan semua masalahnya.

### 4a. Mode `ssh_tunnel`

fumehood hanya mendengarkan di `127.0.0.1:4000`. Orang mengaksesnya lewat
SSH tunnel, dan fumehood tahu siapa mereka dari user Linux pemilik koneksi
tunnel tersebut.

Izinkan SSH lewat IAP (sekali per jaringan):

```sh
gcloud compute firewall-rules create allow-iap-ssh \
  --network=NETWORK --direction=INGRESS --action=allow \
  --rules=tcp:22 --source-ranges=35.235.240.0/20
```

Beri akses ke setiap orang (lebih baik lagi, ke sebuah grup):

```sh
gcloud projects add-iam-policy-binding PROJECT \
  --member=group:engineering@example.com --role=roles/iap.tunnelResourceAccessor
gcloud compute instances add-iam-policy-binding fumehood --zone=ZONE \
  --member=group:engineering@example.com --role=roles/compute.osLogin
```

Pakai `roles/compute.osLogin`, bukan `osAdminLogin`: root di VM bisa
menyamar sebagai siapa saja.

Lalu setiap orang menjalankan:

```sh
gcloud compute ssh fumehood --tunnel-through-iap -- -N -L 4000:localhost:4000
```

dan membuka <http://localhost:4000>. Audit log mencatat username OS Login
mereka (misalnya `jane_example_com`).

### 4b. Mode `iap`

fumehood berada di belakang HTTPS load balancer dengan Identity-Aware Proxy,
dan memeriksa header IAP yang ditandatangani di setiap request.

1. Masukkan VM ke *unmanaged instance group* dengan named port `http:4000`.
2. Buat health check di port 4000, path `/health`.
3. Buat backend service (HTTP) dengan instance group dan health check
   tersebut, lalu external HTTPS load balancer dengan sertifikat yang dikelola
   Google untuk nama host Anda.
4. Izinkan load balancer dan health check menjangkau VM:

   ```sh
   gcloud compute firewall-rules create allow-lb-fumehood \
     --network=NETWORK --direction=INGRESS --action=allow \
     --rules=tcp:4000 --source-ranges=130.211.0.0/22,35.191.0.0/16
   ```

5. Aktifkan IAP untuk backend service tersebut dan berikan akses:

   ```sh
   gcloud iap web enable --resource-type=backend-services --service=fumehood
   gcloud iap web add-iam-policy-binding --resource-type=backend-services \
     --service=fumehood --member=group:engineering@example.com \
     --role=roles/iap.httpsResourceAccessor
   ```

6. Di `/etc/fumehood/fumehood.env`, isi:

   ```sh
   PHX_HOST=fumehood.example.com
   FUMEHOOD_IAP_AUDIENCE=/projects/PROJECT_NUMBER/global/backendServices/SERVICE_ID
   ```

   `SERVICE_ID` adalah id numerik:
   `gcloud compute backend-services describe fumehood --global --format='value(id)'`.
   Lalu `sudo systemctl restart fumehood`.

Audit log mencatat email akun Google setiap orang.

Image Docker juga bisa dipakai untuk mode `iap` di host mana pun di belakang
load balancer yang sama; mode `ssh_tunnel` perlu pemasangan systemd, karena
membaca pemilik socket dan user OS Login langsung dari VM.

## Upgrade

Build tarball yang baru dan jalankan `install.sh`-nya dengan cara yang sama.
Release baru dipasang di sebelah yang lama, `/opt/fumehood` diarahkan ke
release baru, konfigurasi dan data tetap disimpan, dan layanan di-restart.
Untuk kembali ke versi sebelumnya, jalankan lagi `install.sh` dari release
lama.

## Sehari-hari

- Log: `journalctl -u fumehood`.
- Audit log: `/var/lib/fumehood/fumehood.db` (SQLite, hanya bisa ditambah),
  juga di tab Audit pada UI.
- Backup: `/var/lib/fumehood/backups/<database>/`, dihapus setelah
  `backup_retention_days` (bawaan 30 hari). Sertakan `/var/lib/fumehood` di
  snapshot disk VM.
- Mencopot: `systemctl disable --now fumehood`, lalu hapus
  `/etc/systemd/system/fumehood.service`, `/opt/fumehood*`, `/etc/fumehood`,
  dan (setelah menyimpan yang Anda perlukan) `/var/lib/fumehood`.
