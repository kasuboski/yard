#!/usr/bin/env bash
set -euo pipefail

# Start a Postgres container for yard durability development.
# Based on gabsurd's bin/postgres.sh but with max_connections=500
# to handle concurrent test connection pools.

CONTAINER_NAME="gabsurd-postgres"
DB_NAME="gabsurd"
DB_USER="gabsurd"
DB_PASS="gabsurd"
DB_PORT="5432"
IMAGE="postgres:17-alpine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
GABSURD_ROOT="${PROJECT_ROOT}/../gabsurd"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "✅ Postgres container '${CONTAINER_NAME}' already running on :${DB_PORT}"
else
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  echo "🚀 Starting Postgres container (max_connections=500)..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    -e POSTGRES_USER="${DB_USER}" \
    -e POSTGRES_PASSWORD="${DB_PASS}" \
    -e POSTGRES_DB="${DB_NAME}" \
    -p "${DB_PORT}:5432" \
    "${IMAGE}" \
    -c max_connections=500

  echo "⏳ Waiting for Postgres to be ready..."
  for i in $(seq 1 30); do
    if docker exec "${CONTAINER_NAME}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
      echo "✅ Postgres is ready!"
      break
    fi
    sleep 1
  done
fi

echo ""
echo "📋 Applying Absurd schema..."
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" < "${GABSURD_ROOT}/priv/stubs.sql" 2>/dev/null || true
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" < "${GABSURD_ROOT}/priv/absurd.sql"

echo "📋 Applying cron test stub..."
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" < "${PROJECT_ROOT}/yard/src/yard/sql/cron_test_stub.sql"

echo "📋 Applying Yard durable schema..."
docker exec -i "${CONTAINER_NAME}" psql -U "${DB_USER}" -d "${DB_NAME}" < "${PROJECT_ROOT}/yard/src/yard/sql/durable_schema.sql"

echo ""
echo "✅ Database ready: postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:${DB_PORT}/${DB_NAME}"
echo ""
echo "Run tests with: cd yard && gleam test"
