#!/bin/sh
set -eu

# This wrapper must run as root. It installs the bind-mounted certificate into
# the data parent with PostgreSQL ownership before re-entering the official
# image entrypoint. Calling postgres directly would skip initdb on an empty
# volume and leave the acceptance owner without its isolated database.
install -m 0644 /run/postgres-tls/server.crt /var/lib/postgresql/server.crt
install -m 0600 /run/postgres-tls/server.key /var/lib/postgresql/server.key
chown postgres:postgres /var/lib/postgresql/server.crt /var/lib/postgresql/server.key
exec /usr/local/bin/docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file=/var/lib/postgresql/server.crt \
  -c ssl_key_file=/var/lib/postgresql/server.key
