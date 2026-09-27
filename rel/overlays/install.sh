#!/bin/sh
# Installs or upgrades fumehood on a VM (Debian 12+ / Ubuntu 24.04+).
# Run from the unpacked release tarball, as root:
#
#   mkdir fumehood && tar -xzf fumehood-VERSION.tar.gz -C fumehood
#   sudo fumehood/install.sh ssh_tunnel     # or: iap
#
# First install: writes /etc/fumehood/{fumehood.toml,fumehood.env} and stops
# so you can fill them in. Upgrade: keeps them and restarts the service.
set -eu

access=${1:-}
case "$access" in
iap | ssh_tunnel) ;;
*) echo "usage: $0 iap|ssh_tunnel" >&2 && exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2 && exit 1; }

src=$(cd "$(dirname "$0")" && pwd)
version=$(cut -d' ' -f2 "$src/releases/start_erl.data")
dest=/opt/fumehood-$version

id fumehood >/dev/null 2>&1 ||
  useradd --system --home-dir /var/lib/fumehood --no-create-home --shell /usr/sbin/nologin fumehood

# The release: root-owned, read-only to the service.
if [ "$src" != "$dest" ]; then
  rm -rf "$dest"
  cp -a "$src" "$dest"
fi
chown -R root:root "$dest"
chmod -R go-w "$dest"
ln -sfn "$dest" /opt/fumehood

# Config: readable by the service; secrets: root only (systemd reads them).
install -d -m 0750 -o root -g fumehood /etc/fumehood
fresh=false
if [ ! -e /etc/fumehood/fumehood.toml ]; then
  install -m 0640 -o root -g fumehood "$dest/fumehood.example.toml" /etc/fumehood/fumehood.toml
  fresh=true
fi
if [ ! -e /etc/fumehood/fumehood.env ]; then
  (
    umask 077
    {
      echo "FUMEHOOD_ACCESS=$access"
      echo "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 -w0)"
      echo "PORT=4000"
      if [ "$access" = iap ]; then
        echo "# From the backend service: /projects/NUMBER/global/backendServices/ID"
        echo "#FUMEHOOD_IAP_AUDIENCE="
        echo "# The host name people open, e.g. fumehood.example.com"
        echo "#PHX_HOST="
      fi
      echo "# One line per database in fumehood.toml, named by its url_env:"
      echo "#ORDERS_PROD_URL=postgres://fumehood_ro:PASSWORD@10.0.0.5/orders"
    } >/etc/fumehood/fumehood.env
  )
  fresh=true
fi

install -m 0644 "$dest/fumehood.service" /etc/systemd/system/fumehood.service
systemctl daemon-reload
systemctl enable --quiet fumehood

if [ "$fresh" = true ]; then
  cat <<MSG
fumehood $version installed. Next:
  1. edit /etc/fumehood/fumehood.toml (your databases)
  2. edit /etc/fumehood/fumehood.env  (their connection strings$([ "$access" = iap ] && echo ", IAP audience, host"))
  3. systemctl start fumehood && journalctl -u fumehood -f
MSG
else
  systemctl restart fumehood
  echo "fumehood $version installed and restarted."
fi
