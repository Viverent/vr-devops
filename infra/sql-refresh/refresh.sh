#!/usr/bin/env bash
set -euo pipefail

# Modes:
#   export-prod-schemas : pg_dump schema-only de prod -> gs://bucket/prod-schemas/<db>.sql
#   dump-beta-data      : pg_dump data-only de beta excluyendo core.lookup_values -> gs://bucket/beta-data/<db>.sql
#   apply-to-dev        : drop tables dev + import schemas + import data

MODE="${MODE:?MODE required (export-prod-schemas|dump-beta-data|apply-to-dev)}"
BUCKET="${BUCKET:?BUCKET required (gs://vr-portal-fb-sql-refresh)}"
DB_HOST="${DB_HOST:?DB_HOST required}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD required (env or secret)}"
DBS="${DBS:?DBS required (comma-separated: catalog_db,collections_db,...)}"

export PGPASSWORD="$DB_PASSWORD"
export PGCONNECT_TIMEOUT=30

IFS=',' read -ra DB_LIST <<< "$DBS"

case "$MODE" in
  export-prod-schemas)
    for db in "${DB_LIST[@]}"; do
      echo "[$(date -Iseconds)] Exporting schema $db"
      pg_dump --host="$DB_HOST" --username="$DB_USER" --schema-only --no-owner --no-privileges --dbname="$db" \
        | gsutil cp - "$BUCKET/prod-schemas/$db.sql"
    done
    ;;
  dump-beta-data)
    for db in "${DB_LIST[@]}"; do
      echo "[$(date -Iseconds)] Dumping data $db (excl core.lookup_values)"
      EXCLUDE_FLAG=""
      if [ "$db" = "core_db_beta" ]; then
        EXCLUDE_FLAG="--exclude-table-data=core.lookup_values"
      fi
      pg_dump --host="$DB_HOST" --username="$DB_USER" --data-only --no-owner --no-privileges --disable-triggers $EXCLUDE_FLAG --dbname="$db" \
        | gsutil cp - "$BUCKET/beta-data/$db.sql"
    done
    ;;
  apply-to-dev)
    for db in "${DB_LIST[@]}"; do
      base=$(echo "$db" | sed 's/_db_dev$//')
      schema_obj="$BUCKET/prod-schemas/${base}_db.sql"
      data_obj="$BUCKET/beta-data/${base}_db_beta.sql"
      echo "[$(date -Iseconds)] Apply to $db (schema=$schema_obj data=$data_obj)"
      psql --host="$DB_HOST" --username="$DB_USER" --dbname="$db" -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;" || true
      gsutil cat "$schema_obj" | psql --host="$DB_HOST" --username="$DB_USER" --dbname="$db" -v ON_ERROR_STOP=1
      gsutil cat "$data_obj"   | psql --host="$DB_HOST" --username="$DB_USER" --dbname="$db" -v ON_ERROR_STOP=1
    done
    ;;
  *)
    echo "Unknown MODE=$MODE"
    exit 1
    ;;
esac

echo "[$(date -Iseconds)] $MODE completed for ${#DB_LIST[@]} dbs"
