#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

output=${1:-}
if [[ -z $output || $output != /* || $output == *'/../'* || $output == */.. || $output == *'/./'* ]]; then
  printf 'release override output must be a normalized absolute path\n' >&2
  exit 1
fi

cat >"$output" <<'YAML'
services:
  postgres:
    environment:
      POSTGRES_DB: plainpost_central
      POSTGRES_HOST_AUTH_METHOD: scram-sha-256
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres-superuser-password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U plainpost -d plainpost_central"]
    labels:
      com.plainpost.release.topology: primary
      com.plainpost.release.postgresql-major: "18"
    volumes:
      - ${PLAINPOST_PRIVATE_ROOT:?required}/central-secrets:/run/secrets:ro
  postgres-node-one:
    profiles: [release-unused]
    environment:
      POSTGRES_HOST_AUTH_METHOD: scram-sha-256
      POSTGRES_PASSWORD_FILE: /run/secrets/node-bootstrap-password
    volumes:
      - ${PLAINPOST_PRIVATE_ROOT:?required}/central-secrets:/run/secrets:ro
  postgres-node-two:
    environment:
      POSTGRES_HOST_AUTH_METHOD: scram-sha-256
      POSTGRES_PASSWORD_FILE: /run/secrets/node-bootstrap-password
    labels:
      com.plainpost.release.topology: replacement-isolated
      com.plainpost.release.node-image: manifest-bound
    volumes:
      - ${PLAINPOST_PRIVATE_ROOT:?required}/central-secrets:/run/secrets:ro
  central:
    image: ${PLAINPOST_RELEASE_CENTRAL_IMAGE:?set verified Central release image}
    environment:
      PLAINPOST_ENV: acceptance
      PLAINPOST_ACCEPTANCE_FILE_SECRET_AUTHORITY: enabled
      PLAINPOST_DATABASE_URL: ""
      PLAINPOST_DELETION_JOURNAL_DATABASE_URL: ""
      PLAINPOST_RATE_LIMIT_PEPPER: ""
      PLAINPOST_DATABASE_URL_FILE: /run/secrets/central-database-url
      PLAINPOST_DELETION_JOURNAL_DATABASE_URL_FILE: /run/secrets/central-deletion-journal-database-url
      PLAINPOST_RATE_LIMIT_PEPPER_FILE: /run/secrets/rate-limit-pepper
    volumes: !override
      - ${PLAINPOST_PRIVATE_ROOT:?required}/artifacts:/artifacts:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/plainpost-public/postgres-ca.pem:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/central-secrets:/run/secrets:ro
  node-one:
    image: ${PLAINPOST_RELEASE_NODE_IMAGE:?set verified Node release image}
    labels:
      com.plainpost.release.topology: primary-node
      com.plainpost.release.node-image: manifest-bound
    depends_on: !override
      central-node-one-tls: {condition: service_healthy}
      minio-init: {condition: service_completed_successfully}
      postgres: {condition: service_healthy}
    volumes: !override
      - ${PLAINPOST_PRIVATE_ROOT:?required}/artifacts:/artifacts:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/public/ca.crt:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/plainpost-public/postgres-ca.pem:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-one-secrets:/run/secrets:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-one-data:/node-data:rw
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-one-data/attachment-staging:/node-attachment-staging:rw
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-one-data/attachments:/node-attachments:rw
  node-two:
    image: ${PLAINPOST_RELEASE_NODE_IMAGE:?set verified Node release image}
    labels:
      com.plainpost.release.topology: replacement-node
      com.plainpost.release.node-image: manifest-bound
    volumes: !override
      - ${PLAINPOST_PRIVATE_ROOT:?required}/artifacts:/artifacts:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/public/ca.crt:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/plainpost-public/postgres-ca.pem:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-two-secrets:/run/secrets:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-two-data:/node-data:rw
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-two-data/attachment-staging:/node-attachment-staging:rw
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-two-data/attachments:/node-attachments:rw
  privacy-audit:
    command: !override
      - -audit-task-7-private-transport
      - -account-database-file
      - /run/central-secrets/central-database-url
      - -node-one-database-file
      - /run/node-one-secrets/audit_database_url
      - -node-two-database-file
      - /run/node-two-secrets/database_url
      - -actual-privacy-patterns
      - /run/private/privacy-patterns
      - -returned-privacy-patterns
      - /run/private/returned-database-privacy-patterns
    volumes: !override
      - ${PLAINPOST_PRIVATE_ROOT:?required}/bin/plainpost-sync-node-acceptance-seed:/plainpost-sync-node-acceptance-seed:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/ca.crt:/run/plainpost-public/postgres-ca.pem:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/central-secrets:/run/central-secrets:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-one-secrets:/run/node-one-secrets:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/node-two-secrets:/run/node-two-secrets:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/privacy-patterns:/run/private/privacy-patterns:ro
      - ${PLAINPOST_PRIVATE_ROOT:?required}/returned-database-privacy-patterns:/run/private/returned-database-privacy-patterns:ro
YAML
chmod 0600 "$output"
