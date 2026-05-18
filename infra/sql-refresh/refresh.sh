#!/usr/bin/env bash
set -euo pipefail

# Modes:
#   export-prod-full : pg_dump schema+data de prod -> gs://bucket/prod-full/<db>.sql
#   apply-to-beta    : drop schema public beta + load prod-full/<db sin sufijo>.sql
#   apply-to-dev     : drop schema public dev  + load prod-full/<db sin sufijo>.sql

MODE="${MODE:?MODE required (export-prod-full|apply-to-beta|apply-to-dev)}"
BUCKET="${BUCKET:?BUCKET required (gs://vr-portal-fb-sql-refresh)}"
DB_HOST="${DB_HOST:?DB_HOST required}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD required (env or secret)}"
DBS="${DBS:?DBS required (comma-separated)}"

export PGPASSWORD="$DB_PASSWORD"
export PGCONNECT_TIMEOUT=30

IFS=',' read -ra DB_LIST <<< "$DBS"

apply_dump_to() {
  local target_db="$1"
  local source_object="$2"
  echo "[$(date -Iseconds)] Apply to $target_db (source=$source_object)"
  # drop dinamico de todos los schemas non-system para garantizar wipe completo antes del load
  psql --host="$DB_HOST" --username="$DB_USER" --dbname="$target_db" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ('information_schema','pg_catalog','pg_toast')
      AND nspname NOT LIKE 'pg_temp_%'
      AND nspname NOT LIKE 'pg_toast_temp_%'
  LOOP
    EXECUTE 'DROP SCHEMA IF EXISTS ' || quote_ident(s) || ' CASCADE';
  END LOOP;
END $$;
CREATE SCHEMA public;
SQL
  gsutil cat "$source_object" \
    | psql --host="$DB_HOST" --username="$DB_USER" --dbname="$target_db" -v ON_ERROR_STOP=1
}

case "$MODE" in
  export-prod-full)
    for db in "${DB_LIST[@]}"; do
      echo "[$(date -Iseconds)] Exporting schema+data $db"
      pg_dump --host="$DB_HOST" --username="$DB_USER" \
              --no-owner --no-privileges --disable-triggers --dbname="$db" \
        | gsutil cp - "$BUCKET/prod-full/$db.sql"
    done
    ;;
  apply-to-beta)
    for db in "${DB_LIST[@]}"; do
      svc=$(echo "$db" | sed 's/_db_beta$//')
      source_obj="$BUCKET/prod-full/${svc}_db_prod.sql"
      apply_dump_to "$db" "$source_obj"
    done
    ;;
  apply-to-dev)
    for db in "${DB_LIST[@]}"; do
      svc=$(echo "$db" | sed 's/_db_dev$//')
      source_obj="$BUCKET/prod-full/${svc}_db_prod.sql"
      apply_dump_to "$db" "$source_obj"
    done
    ;;
  *)
    echo "Unknown MODE=$MODE"
    exit 1
    ;;
esac

echo "[$(date -Iseconds)] $MODE completed for ${#DB_LIST[@]} dbs"
