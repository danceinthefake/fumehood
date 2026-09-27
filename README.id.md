# fumehood

[English](README.md) · Bahasa Indonesia

Menjalankan query ke PostgreSQL produksi dengan aman: perintah berbahaya
diblokir, setiap query berjalan di dalam transaksi, setiap `UPDATE` /
`DELETE` di-backup sebelum commit, dan setiap tindakan tercatat di audit log.

- Query baca berjalan di transaksi read-only dengan batas jumlah baris dan
  batas waktu.
- Query tulis selalu lewat dry run dulu: Anda melihat berapa baris yang
  berubah dan seperti apa hasilnya, baru kemudian mengonfirmasi.
- Sebelum query tulis di-commit, baris-baris yang berubah disimpan ke CSV;
  tab Backups bisa mengembalikannya, juga lewat dry run → konfirmasi.
- DDL, `TRUNCATE`, query tulis tanpa `WHERE`, dan lainnya diblokir dengan
  mem-parse SQL memakai parser milik Postgres sendiri.
- Siapa melakukan apa tercatat di audit log yang hanya bisa ditambah, tampil
  langsung di UI.
- Tanpa akun user: orang masuk lewat Google Cloud IAP atau SSH tunnel, dan
  IAM yang menentukan siapa yang boleh masuk.

Dibangun dengan Elixir, Phoenix, dan Vue ([blessing-ui](https://www.npmjs.com/package/blessing-ui)).

- Pemasangan: [docs/install.id.md](docs/install.id.md)
- Role Postgres, rahasia, dua instance: [docs/setup.id.md](docs/setup.id.md)
- Desain (bahasa Inggris): [DESIGN.md](DESIGN.md)
- Perubahan: [CHANGELOG.md](CHANGELOG.md)
