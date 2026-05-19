# SQL Refresh Pipeline — dev

Pipeline para refrescar dev con schemas de prod + data de beta. Excluye `core.lookup_values` (seed estructural).

## Componentes

- `Dockerfile` — google/cloud-sdk:slim + postgresql-client-15
- `refresh.sh` — orchestrator. Modes:
  - `export-prod-schemas` (pg_dump schema-only)
  - `dump-beta-data` (pg_dump data-only, excluye core.lookup_values)
  - `apply-to-dev` (DROP SCHEMA public + import schemas + import data)
- Bucket cross-env: `gs://vr-portal-fb-sql-refresh` en project `vr-portal-fb` (lifecycle 7d delete)
- Image AR dev: `us-central1-docker.pkg.dev/vr-portal-fb-dev/services/sql-refresh:v1`
- GH workflow: `.github/workflows/sql-refresh-dev.yml` (workflow_dispatch con confirm=YES)

## Pendiente activar — comandos `gcloud run jobs create`

Necesitan: SQL private IP prod + beta, DB password secrets, VPC connectors. Webmaster no tiene visibilidad SQL prod. Adrián con `cloudsql.admin` puede auditar:

```bash
# prod
gcloud sql instances describe viverent-portal-pg --project=vr-portal-fb \
  --format='value(ipAddresses[?type=PRIVATE].ipAddress,settings.ipConfiguration.privateNetwork)'

# beta
gcloud sql instances describe viverent-portal-pg-beta --project=vr-portal-fb-beta \
  --format='value(ipAddresses[?type=PRIVATE].ipAddress)'
```

Después crear 3 jobs (templates abajo, sustituir `<PROD_DB_HOST>` y `<BETA_DB_HOST>`):

```bash
# Job 1: export-prod-schemas (prod project)
gcloud run jobs create sql-refresh-export-prod \
  --image=us-central1-docker.pkg.dev/vr-portal-fb-dev/services/sql-refresh:v1 \
  --region=us-central1 --project=vr-portal-fb \
  --service-account=sa-cloud-run-jobs@vr-portal-fb.iam.gserviceaccount.com \
  --vpc-connector=viverent-portal-connector --vpc-egress=private-ranges-only \
  --set-env-vars="MODE=export-prod-schemas,BUCKET=gs://vr-portal-fb-sql-refresh,DB_HOST=<PROD_DB_HOST>,DB_USER=postgres,DBS=catalog_db,collections_db,contracts_db,core_db,finance_db,identity_db,persons_db,rentals_db,sales_db,tickets_db" \
  --set-secrets="DB_PASSWORD=pg_superuser_password:latest" \
  --task-timeout=3600 --max-retries=0

# Job 2: dump-beta-data (beta project)
gcloud run jobs create sql-refresh-dump-beta \
  --image=us-central1-docker.pkg.dev/vr-portal-fb-dev/services/sql-refresh:v1 \
  --region=us-central1 --project=vr-portal-fb-beta \
  --service-account=sa-cloud-run-jobs-beta@vr-portal-fb-beta.iam.gserviceaccount.com \
  --vpc-connector=viverent-conn-beta --vpc-egress=private-ranges-only \
  --set-env-vars="MODE=dump-beta-data,BUCKET=gs://vr-portal-fb-sql-refresh,DB_HOST=<BETA_DB_HOST>,DB_USER=postgres,DBS=catalog_db_beta,collections_db_beta,contracts_db_beta,core_db_beta,finance_db_beta,identity_db_beta,persons_db_beta,rentals_db_beta,sales_db_beta,tickets_db_beta" \
  --set-secrets="DB_PASSWORD=beta_pg_superuser_password:latest" \
  --task-timeout=3600 --max-retries=0

# Job 3: apply-to-dev (dev project — DB_HOST conocido 10.80.0.3)
gcloud run jobs create sql-refresh-apply-dev \
  --image=us-central1-docker.pkg.dev/vr-portal-fb-dev/services/sql-refresh:v1 \
  --region=us-central1 --project=vr-portal-fb-dev \
  --service-account=sa-cloud-run-jobs-dev@vr-portal-fb-dev.iam.gserviceaccount.com \
  --vpc-connector=viverent-conn-dev --vpc-egress=private-ranges-only \
  --set-env-vars="MODE=apply-to-dev,BUCKET=gs://vr-portal-fb-sql-refresh,DB_HOST=10.80.0.3,DB_USER=postgres,DBS=catalog_db_dev,collections_db_dev,contracts_db_dev,core_db_dev,finance_db_dev,identity_db_dev,persons_db_dev,rentals_db_dev,sales_db_dev,tickets_db_dev" \
  --set-secrets="DB_PASSWORD=dev_pg_superuser_password:latest" \
  --task-timeout=3600 --max-retries=0
```

## Trigger

Después de crear los 3 jobs, ejecutar manualmente:

```bash
gh workflow run sql-refresh-dev.yml --repo Viverent/vr-devops -f confirm=YES
```

O via GitHub UI: Actions → SQL Refresh Dev → Run workflow → confirm=YES.

## Seguridad

- Bucket lifecycle: delete después 7d (no stale dumps).
- Triple `--data-only` + `--no-owner` + `--no-privileges` evita pisar grants.
- `--disable-triggers` evita FK explosions durante import data.
- DEV apply hace `DROP SCHEMA public CASCADE` — pierde TODO en dev. Por eso confirm=YES gate.
- `core.lookup_values` excluido (seed estructural, no se sobrescribe).
