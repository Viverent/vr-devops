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
│   ├── deploy-frontend.yml        Reusable frontend (Firebase Hosting)
│   ├── ci-frontend.yml            Reusable PR validation frontends
│   └── deploy-router.yml          Reusable apollo-router + auth-validator
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

## Reusables disponibles

### `deploy-microservice.yml` — Backend deploys (Tier 1-3)

Build + push image (con GHA layer cache) + render YAML + migrate job
(replace + execute) + Cloud Run replace + smoke /health + **rollback
automático** si smoke falla.

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `service_name` | string | requerido | Cloud Run service base. Ej: `ms-sales-api`. |
| `image_name` | string | requerido | Slug subgrafo (sin prefijo `ms-`). Ej: `sales`. |
| `env` | string | requerido | Target environment (`beta` o `prod`). |
| `migrate_mode` | string | `auto` | `auto` \| `always` \| `never`. |
| `smoke_timeout_seconds` | number | `60` | Tiempo total /health smoke. |
| `migrate_timeout_minutes` | number | `30` | Timeout para `gcloud run jobs execute --wait`. |

#### Caller ejemplo

```yaml
# ms-sales-api/.github/workflows/deploy-beta.yml
name: Deploy Beta
on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: Viverent/vr-devops/.github/workflows/deploy-microservice.yml@main
    with:
      service_name: ms-sales-api
      image_name: sales
      env: beta
    secrets: inherit
```

---

### `ci-backend.yml` — Backend PR validation

Lint (ruff) + format check + Postgres ephemeral + alembic migrations
opcionales + pytest. Sin deploy.

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `python_version` | string | `3.12` | Python para runner |
| `run_tests` | boolean | `true` | Si false, salta pytest |
| `postgres_version` | string | `15-alpine` | Tag postgres service container |
| `database_url` | string | `postgresql+asyncpg://test:test@localhost:5432/test_db` | URL para tests |
| `pg_extensions` | string | `""` | Comma-separated extensions Postgres a CREATE EXTENSION. Ej: `"uuid-ossp,citext"` |
| `apply_migrations` | boolean | `false` | Si true, corre `alembic upgrade head` antes de pytest |
| `extra_env` | string (JSON) | `"{}"` | Env vars adicionales para pytest |

#### Caller ejemplo (con migrations + extensions)

```yaml
# ms-sales-api/.github/workflows/ci.yml
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  ci:
    uses: Viverent/vr-devops/.github/workflows/ci-backend.yml@main
    with:
      pg_extensions: "uuid-ossp,citext"
      apply_migrations: true
```

---

### `deploy-frontend.yml` — Frontend deploys (Tier 2)

Auth WIF + npm ci + npm run build (vite mode env) + firebase deploy a
hosting target especifico + smoke HEAD opcional.

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `hosting_target` | string | requerido | Firebase target (ej. `backoffice-beta`) |
| `env` | string | requerido | `beta` o `prod` |
| `working_directory` | string | `.` | Subdir donde vive package.json (ej. `frontend` para portal-tickets-ui) |
| `node_version` | string | `20` | Node version |
| `smoke_url` | string | `""` | URL para smoke HEAD opcional |
| `smoke_timeout_seconds` | number | `60` | Tiempo gracia smoke |

Nota: requiere que `.env.${env}` exista en el `working_directory` del
repo (Vite lo lee con `--mode ${env}`). Per S01, los 3 frontends tienen
`.env.beta` committeado.

---

### `ci-frontend.yml` — Frontend PR validation

npm ci + ESLint (si configurado) + tsc --noEmit + Vitest. Sin deploy.

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `working_directory` | string | `.` | Subdir donde vive package.json |
| `node_version` | string | `20` | Node version |
| `run_tests` | boolean | `true` | Si false, salta vitest |
| `run_lint` | boolean | `true` | Si false, salta ESLint step |

---

### `deploy-router.yml` — Apollo Router + auth-validator (Tier 3)

Build + push DOS imagenes (router + auth-validator) + render YAMLs +
deploy ambos services + smoke contra auth-validator.

**LIMITACION ACTUAL:** la composición del supergraph (rover compose
sobre 10 SDLs) requiere acceso a `/internal/schema` de cada subgrafo,
los cuales tienen `ingress=internal`. El runner GitHub Actions externo
no llega al VPC interno. Soluciones futuras:
- (A) Cloud Run Job de compose triggereado vía `repository_dispatch`.
- (B) Pub/Sub fanout: cada subgrafo publica su SDL al cambiar.
- (C) Apollo GraphOS managed (paid).

Hasta resolver, el workflow asume que `composed.graphql` ya está
committeado en el repo (modo bootstrap manual).

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `env` | string | requerido | `beta` o `prod` |
| `router_image_name` | string | `apollo-router` | Image repo en AR |
| `auth_validator_image_name` | string | `auth-validator` | Image repo en AR |
| `compose_supergraph` | boolean | `false` | TODO Tier 3 mature. Por ahora forzado false. |
| `smoke_timeout_seconds` | number | `90` | Smoke contra auth-validator /graphql |

---

## Action SHA pinning (anti supply-chain)

Todas las actions externas pinned a SHA específico (no tag mutable).
SHAs verificados con `gh api repos/<repo>/git/refs/tags/<tag>` el
2026-05-10.

| Action | SHA | Tag |
|--------|-----|-----|
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` | v4 |
| `actions/setup-python` | `a26af69be951a213d495a4c3e4e4022e16d87065` | v5 |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | v4 |
| `google-github-actions/auth` | `c200f3691d83b41bf9bbd8638997a462592937ed` | v2 |
| `google-github-actions/setup-gcloud` | `e427ad8a34f8676edf47cf7d7925499adf3eb74f` | v2 |
| `docker/setup-buildx-action` | `8d2750c68a42422c14e847fe6c8ac0403b4cbd6f` | v3 |
| `docker/build-push-action` | `10e90e3645eae34f1e60eeb005ba3a3d33f178e8` | v6 |

### Cómo verificar / actualizar SHAs

```bash
# Verificar SHA actual de un tag:
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'

# Si es annotated tag, dereferenciar:
sha=$(gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha')
gh api repos/actions/checkout/git/tags/$sha --jq '.object.sha'
```

Recomendado: configurar Dependabot:

```yaml
# .github/dependabot.yml
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
  workstation; los runners CI usan `$GITHUB_WORKSPACE`.

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

- **Pipeline beta**: push a `main` de cualquier caller dispara deploy.
- **Pipeline prod**: diferido a S12. SA `gh-actions-prod` existe pero
  ningún workflow lo invoca todavía.
- **Reusable workflows en este repo**: pinear con `@main` durante S09
  estabilización. Cuando madure, evaluar tags semver `@v1.0.0`.

---

## Tier rollout (S09)

Estrategia escalonada para limitar blast radius:

| Tier | Repos | Reusables aplicables | Status |
|------|-------|----------------------|--------|
| 1 | `ms-sales-api`, `ms-rentals-api`, `ms-collections-api` | `ci-backend`, `deploy-microservice` | onboarding actual |
| 2 | `ms-catalog-api`, `ms-persons-api`, 3 frontends | `ci-backend`, `deploy-microservice`, `ci-frontend`, `deploy-frontend` | post Tier 1 verde |
| 3 | `ms-core-api`, `ms-identity-api`, `ms-tickets-api`, `ms-contracts-api`, `ms-finance-api`, `portal-inversionistas-api` | + `deploy-router` | último, con confianza |

---

## Concurrency strategy

| Reusable | Concurrency group | cancel-in-progress |
|----------|-------------------|-------------------|
| `deploy-microservice` | `deploy-${service}-${env}` | `false` (serializa) |
| `deploy-frontend` | `deploy-frontend-${target}-${env}` | `false` (serializa) |
| `deploy-router` | `deploy-router-${env}` | `false` (serializa) |
| `ci-backend` | `ci-${workflow}-${ref}` | `true` (cancela viejos) |
| `ci-frontend` | `ci-frontend-${workflow}-${ref}` | `true` (cancela viejos) |

Razón: deploys nunca cancelan (asegura que todos lleguen a runtime,
serializados). CI cancela porque pushes nuevos al PR invalidan resultados
viejos — no tiene sentido seguir gastando minutos en commits superados.

---

## Troubleshooting

Ver `docs/CI_CD_WIF.md` (sección 7) en orchestrator para errores de
auth comunes y diagnóstico.

### Errores específicos `deploy-microservice.yml`

| Síntoma | Causa | Fix |
|---------|-------|-----|
| `Image $IMAGE_TAG already in AR, skip rebuild` + deploy falla con `image not found` | Tag existe en AR pero el path está mal calculado | Verificar `MS_IMAGE_SUFFIX` en env file y `image_name` input |
| `Migrate job ... declared required (mode=always) but does not exist` | Caller declaró `migrate_mode: always` pero el job no existe en runtime | Crear job con primer deploy, o cambiar a `mode: auto` |
| `Smoke /health failed after Xs` + rollback message | Nueva revisión no responde 200 a `/health` | Cloud Logging filter `resource.labels.revision_name="..."` |
| `Could not find ref main` (en checkout vr-devops) | Branch `main` de vr-devops no existe en remote | Push inicial de vr-devops faltante |

### Errores específicos `ci-backend.yml`

| Síntoma | Causa | Fix |
|---------|-------|-----|
| `psql: error: ... could not connect to server` | Postgres service no up todavía | Health check timeout — investigar logs del job |
| `function uuid_generate_v4() does not exist` | Falta `pg_extensions` con `uuid-ossp` | Agregar `pg_extensions: "uuid-ossp"` al caller |
| `apply_migrations=true pero alembic.ini no existe` | Repo no tiene alembic configurado | Cambiar `apply_migrations: false` o agregar alembic.ini |
| `ENV must be one of [...]` en pytest | El config.py de tu repo agregó `Literal` con valores extra | Usar `extra_env: '{"ENV":"..."}'` para sobreescribir |

### Errores específicos `deploy-router.yml`

| Síntoma | Causa | Fix |
|---------|-------|-----|
| `compose_supergraph=true no soportado en S09` | Feature no implementada todavía | Mantener `compose_supergraph: false` y commitear `composed.graphql` manualmente |
| `No supergraph.graphql / composed.graphql found` | Falta archivo composed pre-built | Correr `bash scripts/compose-supergraph.sh` localmente y commitear |

---

## TODO post-S09 inicial

- [ ] Cloud Run Job para compose-supergraph automatizado (Tier 3 mature)
- [ ] `repository_dispatch` desde subgrafo a router al cambiar SDL
- [ ] Secret scanning + CodeQL workflows (S14)
- [ ] Self-hosted runner si excede free tier (S13)
- [ ] Dependabot config para bumpear action SHAs
- [ ] Migration a tags semver `@v1.0.0` para reusables cuando estabilicen
