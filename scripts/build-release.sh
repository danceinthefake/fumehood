#!/bin/sh
# Builds the release tarball for the VM install into dist/, using the
# Dockerfile's build stage (so it runs on Debian 12+ / Ubuntu 24.04+).
set -eu
cd "$(dirname "$0")/.."
docker build --target build -t fumehood-build .
id=$(docker create fumehood-build)
trap 'docker rm "$id" >/dev/null' EXIT
mkdir -p dist
docker cp "$id:/app/_build/prod/" - | tar -x -C dist --strip-components=1 --wildcards 'prod/fumehood-*.tar.gz'
ls dist/fumehood-*.tar.gz
