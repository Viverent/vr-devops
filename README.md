# vr-devops — CI/CD reusable workflows + infra templates

Repo central para los pipelines GitHub Actions de la organización
`Viverent`. Aterriza reusable workflows + scripts + templates Cloud Run
que los 14 repos productivos (10 backends, 1 router, 3 frontends)
invocan desde sus propios `.github/workflows/`.

---

## Estructura

```
vr-devops/
├── .github/workflows/
│   ├── deploy-microservice.yml    Reusable backend (ms-*-api)
│   ├── ci-backend.yml             Reusable PR validation backends
│   ├── deploy-frontend.yml        TODO Tier 2 (Firebase Hosting)
│   └── deploy-router.yml          TODO Tier 3 (apollo-router + supergraph)
├── scripts/
│   └── render-cloudrun.sh         Renderiza YAML Cloud Run via envsubst
├── infra/
│   ├── env/
│   │   ├── beta.env               Vars beta (PROJECT_ID, VPC, SQL, etc)
│   │   └── prod.env               Vars prod (FREEZE hasta S12)
│   └── cloud-run-templates/
│       ├── subgraph.template.yaml Service Cloud Run para ms-*
│       ├── job.template.yaml      Job Cloud Run para alembic migrate
│       └── allowlist.txt          Vars permitidas en envsubst
└── README.md
```

---

## Cómo usar (caller-side)

### Ejemplo backend `ms-sales-api/.github/workflows/deploy-beta.yml`

```yaml
name: Deploy Beta
on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: Viverent/vr-devops/.github/workflows/deploy-microservice.yml@main
    with:
      service_name: ms-sales-api
      image_name: sales            # slug, sin prefijo "ms-"
      env: beta
      # migrate_mode: auto         # default
    secrets: inherit
```

### Ejemplo backend `ms-sales-api/.github/workflows/ci.yml`

```yaml
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: Viverent/vr-devops/.github/workflows/ci-backend.yml@main
    # Para repos con tests dependientes de Redis/secrets reales:
    # with:
    #   extra_env: '{"REDIS_URL":"redis://localhost:6379"}'
```

---

## Reusable: `deploy-microservice.yml`

Build + push image + render YAML + Cloud Run replace + migrate
(replace job + execute) + smoke /health + **rollback automático** si
smoke falla.

### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `service_name` | string | requerido | Cloud Run service base (sin sufijo `-beta`/`-prod`). Ej: `ms-sales-api`. |
| `image_name` | string | requerido | Slug subgrafo (sin prefijo `ms-`). Ej: `sales`, `tickets`, `identity`. |
| `env` | string | requerido | Target environment (`beta` o `prod`). |
| `migrate_mode` | string | `auto` | Comportamiento migrate: `auto` \| `always` \| `never`. |
| `smoke_timeout_seconds` | number | `60` | Tiempo total /health smoke con retry. |
| `migrate_timeout_minutes` | number | `30` | Timeout para `gcloud run jobs execute --wait`. |

### `migrate_mode` comportamiento

| Valor | Cuándo correr migrate | Qué pasa si job no existe |
|-------|----------------------|---------------------------|
| `auto` (default) | Si `ms-${slug}-migrate-${env}` existe en runtime | Skip silencioso con `::notice::` |
| `always` | Siempre — fail si no existe | Workflow falla con `::error::` |
| `never` | Nunca | N/A |

Útil:
- `auto` — onboarding generalizado, low-risk.
- `always` — repos con migrations críticas (`ms-identity`, `ms-core`) — fail si alguien borra el job.
- `never` — hotfix sin schema change, downtime cero.

### Rollback automático

Si `/health` smoke falla post-deploy:
1. Revisión rota se queda en historial Cloud Run pero **NO recibe tráfico**.
2. `update-traffic` restaura 100% del tráfico a la revisión previa (capturada en step 6).
3. Workflow termina con `failure` para que el trigger humano sepa.
4. Si fue primer deploy (sin revisión previa), rollback skippea — operador debe investigar manual.

### Concurrency

Workflow tiene `concurrency: deploy-${service_name}-${env}` con
`cancel-in-progress: false`. Dos pushes a `main` del mismo repo
**serializan en orden de llegada**, no compiten ni se cancelan.

---

## Reusable: `ci-backend.yml`

Lint (ruff) + format check + pytest contra Postgres ephemeral. Sin
deploy.

### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `python_version` | string | `3.12` | Python para runner |
| `run_tests` | boolean | `true` | Si false, salta pytest |
| `postgres_version` | string | `15-alpine` | Tag postgres service container |
| `database_url` | string | `postgresql+asyncpg://test:test@localhost:5432/test_db` | URL para tests |
| `extra_env` | string (JSON) | `"{}"` | Env vars adicionales para pytest |

### Service container Postgres

CI levanta un Postgres efímero con health check antes de correr pytest.
`DATABASE_URL` apunta a `localhost:5432` (port mapeado al runner).

Si tu repo necesita Redis u otros servicios, usa `extra_env` con JSON:

```yaml
with:
  extra_env: '{"REDIS_URL":"redis://localhost:6379","INTERNAL_HMAC_SECRET":"test-secret-32-bytes-long-pls"}'
```

Soportados via `extra_env`:
- `REDIS_URL`
- `INTERNAL_HMAC_SECRET` (default `test-hmac-secret`)
- `MS_IDENTITY_URL`
- `MS_CONTRACTS_URL`
- `ATTACHMENT_BUCKET` (default `test-bucket`)
- `GCS_DOCUMENTS_BUCKET` (default `test-bucket`)
- `GCP_PROJECT_ID` (default `local-dev`)

Para añadir vars nuevas, editar el `env:` block en `ci-backend.yml`.

### Concurrency

`cancel-in-progress: true` — pushes nuevos al mismo PR cancelan runs
viejos para ahorrar minutos CI (a diferencia de deploy que serializa).

---

## Action SHA pinning (anti supply-chain)

Todas las actions externas pinned a SHA específico (no tag mutable).
Tags como `@v4` son referencias mutables — un atacante con acceso al
repo de la action puede repushear el tag con código malicioso.

### Actions usadas + SHAs actuales

| Action | SHA | Versión |
|--------|-----|---------|
| `actions/checkout` | `692973e3d937129bcbf40652eb9f2f61becf3332` | v4.1.7 |
| `actions/setup-python` | `0b93645e9fea7318ecaed2b359559ac225c90a2b` | v5.3.0 |
| `google-github-actions/auth` | `6fc4af4b145ae7821d527454aa9bd537d1f2dc5f` | v2.1.7 |
| `google-github-actions/setup-gcloud` | `f0490c7e624c3d6d54ed447a8b5e45ddc4d8c5f` | v2.1.2 |

### Cómo verificar / actualizar SHAs

```bash
# Verificar SHA actual de un tag:
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'

# Cuando sale nueva version (ej. v4.2.0), bumpear:
#   1. gh api ese repo/git/refs/tags/v4.2.0 --jq '.object.sha'
#   2. Reemplazar SHA en .github/workflows/*.yml
#   3. Actualizar tabla de arriba
```

Recomendado: configurar Dependabot (`.github/dependabot.yml`) con:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
```

---

## Sincronización con orchestrator local

Source of truth para cambios: orchestrator workspace
(`/Users/a.a/Desktop/ReposMicroservices/`). Este repo es **mirror** de
los archivos que el runner de GitHub Actions necesita.

### Files mirrored

| vr-devops path | Orchestrator path |
|----------------|-------------------|
| `scripts/render-cloudrun.sh` | `scripts/render-cloudrun.sh` |
| `infra/env/beta.env` | `infra/env/beta.env` |
| `infra/env/prod.env` | `infra/env/prod.env` |
| `infra/cloud-run-templates/*` | `infra/cloud-run-templates/*` |

### Diferencias intencionales

- **`REPOS_ROOT` comentado** en env mirrors. Era path local
  workstation; los runners CI usan `$GITHUB_WORKSPACE`. Comentado para
  evitar ruido sin perder la documentación de su propósito.

### Sync command

```bash
ORCH=/Users/a.a/Desktop/ReposMicroservices
VR=/Users/a.a/Desktop/ReposMicroservices/Beta/repos/vr-devops

cp $ORCH/scripts/render-cloudrun.sh           $VR/scripts/
cp $ORCH/infra/env/beta.env                    $VR/infra/env/
cp $ORCH/infra/env/prod.env                    $VR/infra/env/
cp $ORCH/infra/cloud-run-templates/*           $VR/infra/cloud-run-templates/

# Re-aplicar diferencias intencionales (REPOS_ROOT comment-out):
sed -i '' 's|^export REPOS_ROOT=|# export REPOS_ROOT=|' $VR/infra/env/*.env

cd $VR && git diff
# Si hay cambios reales, commitear
```

---

## Auth: WIF (Workload Identity Federation)

Setup S08 documentado en orchestrator: `docs/CI_CD_WIF.md`.

| Env | Provider URI | SA email |
|-----|--------------|----------|
| beta | `projects/214382208885/locations/global/workloadIdentityPools/github-pool/providers/github-actions` | `gh-actions-beta@vr-portal-fb-beta.iam.gserviceaccount.com` |
| prod | `projects/126856503055/locations/global/workloadIdentityPools/github-pool/providers/github-actions` | `gh-actions-prod@vr-portal-fb.iam.gserviceaccount.com` |

Bindings:
- **Beta**: org-scoped (cualquier repo de Viverent puede impersonar).
- **Prod**: repo-specific allowlist (14 repos explícitos).

---

## Branching strategy

- **Pipeline beta**: push a `main` de cualquier caller dispara
  `deploy-microservice.yml` con `env: beta`.
- **Pipeline prod**: diferido a S12. El SA `gh-actions-prod` existe
  pero ningún workflow lo invoca todavía.
- **Reusable workflows en este repo**: pinear con `@main` durante S09
  estabilización. Cuando madure, evaluar tags semver `@v1.0.0`.

---

## Tier rollout (S09)

Estrategia escalonada para limitar blast radius:

| Tier | Repos | Status |
|------|-------|--------|
| 1 | `ms-sales-api`, `ms-rentals-api`, `ms-collections-api` | onboarding actual |
| 2 | `ms-catalog-api`, `ms-persons-api`, frontends | post Tier 1 verde |
| 3 | `ms-core-api`, `ms-identity-api`, `ms-tickets-api`, `ms-contracts-api`, `ms-finance-api`, `portal-inversionistas-api` | último, con confianza |

---

## Troubleshooting

Ver `docs/CI_CD_WIF.md` (sección 7) en orchestrator para errores de
auth comunes y diagnóstico.

### Errores específicos `deploy-microservice.yml`

| Síntoma | Causa | Fix |
|---------|-------|-----|
| `Image $IMAGE_TAG already in AR, skip rebuild` + deploy falla con `image not found` | Tag existe en AR pero el path está mal calculado | Verificar `MS_IMAGE_SUFFIX` en env file y `image_name` input |
| `Migrate job ... declared required (mode=always) but does not exist` | Caller declaró `migrate_mode: always` pero el job no existe en runtime | Crear job con `gcloud run jobs replace`, o cambiar a `mode: auto` |
| `Smoke /health failed after Xs` + rollback message | Nueva revisión no responde 200 a `/health` | Revisar logs Cloud Run de la revisión recién deployada — Cloud Logging filter `resource.labels.revision_name="..."` |
| `Could not find ref main` (en checkout vr-devops) | Branch `main` de vr-devops no existe en remote | Push inicial de vr-devops faltante (Fase 3 de S09) |

---

## TODO post-S09 inicial

- [ ] `deploy-frontend.yml` reusable para Firebase Hosting (Tier 2)
- [ ] `deploy-router.yml` reusable con supergraph compose (Tier 3)
- [ ] `ci-frontend.yml` reusable (ESLint + Vitest + tsc --noEmit)
- [ ] `repository_dispatch` desde subgrafo a router al cambiar SDL
- [ ] Secret scanning + CodeQL workflows (S14)
- [ ] Self-hosted runner si excede free tier (S13)
- [ ] Dependabot config para bumpear action SHAs
- [ ] Migration a tags semver `@v1.0.0` para reusables cuando estabilicen
