# vr-devops — CI/CD reusable workflows + infra templates

Repo central para los pipelines GitHub Actions de la organización
`Viverent`. Aterriza reusable workflows + scripts + templates Cloud Run
que los 14 repos productivos (10 backends, 1 router, 3 frontends)
invocan desde sus propios `.github/workflows/`.

---

## Estructura

```
vr-devops/
├── .github/
│   ├── workflows/
│   │   ├── deploy-microservice.yml    Reusable backend (ms-*-api)
│   │   ├── ci-backend.yml             Reusable PR validation backends
│   │   ├── deploy-frontend.yml        Reusable frontend (Firebase Hosting)
│   │   ├── ci-frontend.yml            Reusable PR validation frontends
│   │   ├── deploy-router.yml          Reusable apollo-router + auth-validator
│   │   └── security-scan.yml          Reusable SAST + dep scan (Semgrep/Bandit/Trivy)
│   └── dependabot.yml                  Auto-update GH Actions SHAs (weekly)
├── scripts/
│   └── render-cloudrun.sh             Renderiza YAML Cloud Run via envsubst
├── infra/
│   ├── env/
│   │   ├── beta.env                   Vars beta (PROJECT_ID, VPC, SQL, etc)
│   │   └── prod.env                   Vars prod (FREEZE hasta S12)
│   └── cloud-run-templates/
│       ├── subgraph.template.yaml     Service Cloud Run para ms-*
│       ├── job.template.yaml          Job Cloud Run para alembic migrate
│       └── allowlist.txt              Vars permitidas en envsubst
├── templates/                          Templates copy-paste para callers
│   ├── dependabot-backend.template.yml
│   ├── dependabot-frontend.template.yml
│   ├── dependabot-auto-merge.template.yml
│   ├── CODEOWNERS.template
│   ├── deploy-prod-with-approval.template.yml
│   └── security-scan-caller.template.yml
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
| `compose_supergraph` | boolean | `false` | Diferido: requiere Cloud Run Job (ver "Compose-supergraph implementation plan" abajo). |
| `smoke_timeout_seconds` | number | `90` | Smoke contra auth-validator /graphql |

---

### `security-scan.yml` — SAST + dependency scan (todos los Tiers)

Reemplaza CodeQL native (que requiere GitHub Advanced Security en
Enterprise) con stack OSS equivalente:
- **Semgrep OSS**: 2000+ reglas community, OWASP Top 10, multi-lenguaje.
- **Bandit**: Python-specific (eval, hardcoded creds, weak crypto).
- **Trivy**: filesystem + dependency CVE scan (requirements.txt,
  package-lock.json, Dockerfile).
- **npm audit**: JavaScript dependency vulnerabilities.

Cada scanner corre como job independiente; falla del scanner falla el
run. Hallazgos detallados en logs (Free plan no tiene Security tab para
repos privados).

#### Inputs

| Input | Type | Default | Descripción |
|-------|------|---------|-------------|
| `language` | string | requerido | `python` \| `javascript` (decide qué scanners corren) |
| `working_directory` | string | `.` | Subdir para deps scan (frontends pueden usar `frontend`) |
| `semgrep_config` | string | `p/security-audit p/owasp-top-ten` | Configs Semgrep separadas por espacio |
| `severity_break` | string | `HIGH` | `HIGH` \| `CRITICAL` — severity mínimo que rompe el run |
| `run_semgrep` | boolean | `true` | Disable Semgrep si false |
| `run_bandit` | boolean | `true` | Disable Bandit (solo aplica a python) |
| `run_trivy` | boolean | `true` | Disable Trivy filesystem scan |
| `run_npm_audit` | boolean | `true` | Disable npm audit (solo aplica a javascript) |

#### Caller ejemplo

Ver `templates/security-scan-caller.template.yml`.

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
| `aquasecurity/trivy-action` | `ed142fd0673e97e23eac54620cfb913e5ce36c25` | v0.36.0 |
| `dependabot/fetch-metadata` | `21025c705c08248db411dc16f3619e6b5f9ea21a` | v2 |
| `trstringer/manual-approval` | `74d99dff7380e3e4b122d4ededcbca2b6ce59367` | v1 |

> **Nota sobre Semgrep**: NO usamos `returntocorp/semgrep-action` (deprecada
> por Semgrep, Inc. — README oficial recomienda migrar a CLI nativo).
> En su lugar instalamos `semgrep` via `pip install --upgrade semgrep`
> en el job — sin action de terceros que pinear.

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
| 1 | `ms-sales-api`, `ms-rentals-api`, `ms-collections-api` | `ci-backend`, `deploy-microservice`, `security-scan` | onboarding actual |
| 2 | `ms-catalog-api`, `ms-persons-api`, 3 frontends | `ci-backend`, `deploy-microservice`, `ci-frontend`, `deploy-frontend`, `security-scan` | post Tier 1 verde |
| 3 | `ms-core-api`, `ms-identity-api`, `ms-tickets-api`, `ms-contracts-api`, `ms-finance-api`, `portal-inversionistas-api` | + `deploy-router` | último, con confianza |

---

## Onboarding checklist por repo (Free plan)

Para un repo nuevo de Tier 1/2/3, pasos en orden:

### 1. Workflows callers (`.github/workflows/`)

Backend:
- [ ] `ci.yml` — caller de `ci-backend.yml` con `pg_extensions` + `apply_migrations: true`
- [ ] `deploy-beta.yml` — caller de `deploy-microservice.yml`
- [ ] `security-scan.yml` — caller de `security-scan.yml` (template `templates/security-scan-caller.template.yml`)
- [ ] `dependabot-auto-merge.yml` — copy de `templates/dependabot-auto-merge.template.yml`

Frontend:
- [ ] `ci.yml` — caller de `ci-frontend.yml`
- [ ] `deploy-beta.yml` — caller de `deploy-frontend.yml`
- [ ] `security-scan.yml` — caller de `security-scan.yml` con `language: javascript`
- [ ] `dependabot-auto-merge.yml` — copy de template

### 2. Config files (`.github/`)

- [ ] `dependabot.yml` — copy del template `dependabot-backend.template.yml` o `dependabot-frontend.template.yml`
- [ ] `CODEOWNERS` — copy de `templates/CODEOWNERS.template`, ajustar paths. **NOTA Free**: archivo decorativo sin enforcement (branch protection no disponible). Activa automáticamente si org upgradea a Team.

### 3. Branch protection — NO disponible en Free

GitHub Free private repos retornan **403 "Upgrade to GitHub Pro"** en
APIs `branches/main/protection` y `rulesets`. Sin enforcement UI:

- ✗ NO se puede requerir PR antes de merge
- ✗ NO se puede requerir approvals
- ✗ NO se puede requerir status checks pass
- ✗ NO se puede bloquear force push
- ✗ NO se puede requerir linear history

Estrategia: soft enforcement (ver "Soft enforcement strategy" en Decisiones documentadas).

> Cuando upgradeen a Team: estos rules se activan automáticamente sin
> tocar workflows. Path: Settings → Rules → Rulesets → New branch ruleset.

### 4. Repo settings disponibles en Free (UI o gh api)

```bash
# Batch via API (correr cuando creen el repo)
for r in vr-devops ms-sales-api ms-rentals-api ms-collections-api; do
  # General settings
  gh api -X PATCH "repos/Viverent/$r" \
    -F allow_auto_merge=true \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true

  # Workflow permissions (requiere org-level enable previo)
  gh api -X PUT "repos/Viverent/$r/actions/permissions/workflow" \
    -f default_workflow_permissions=write \
    -F can_approve_pull_request_reviews=true
done
```

UI alternativa (`Settings`):

**General → Pull Requests:**
- ☑ Allow auto-merge (CRÍTICO para dependabot-auto-merge)
- ☑ Allow squash merging
- ☐ Allow merge commits (UNCHECK)
- ☐ Allow rebase merging (UNCHECK)
- ☑ Automatically delete head branches

**Actions → General → Workflow permissions:**
- Selecciona "Read and write permissions" (radio button)
- ☑ **Allow GitHub Actions to create and approve pull requests** (CRÍTICO)
  - REQUIERE primero habilitarlo a nivel ORG (`/organizations/Viverent/settings/actions`)

**Code security → Dependabot:**
- ☑ Dependabot alerts
- ☑ Dependabot security updates

**Code security → Secret scanning:**
- ✗ NO disponible en Free private repos. Cobertura via `security-scan.yml` workflow (Trivy + Semgrep).

### 5. Validación post-onboarding

```bash
gh api repos/Viverent/<repo> --jq '{
  auto_merge: .allow_auto_merge,
  squash_only: (.allow_squash_merge and not .allow_merge_commit and not .allow_rebase_merge),
  delete_branch: .delete_branch_on_merge,
  dependabot_sec: .security_and_analysis.dependabot_security_updates.status
}'
gh api repos/Viverent/<repo>/actions/permissions/workflow
```

Esperado:
- `auto_merge: true`
- `squash_only: true`
- `delete_branch: true`
- `dependabot_sec: enabled`
- `default_workflow_permissions: write`
- `can_approve_pull_request_reviews: true`

### 6. Validación E2E (post-Fase 3 push)

- [ ] PR de prueba: tocar `app/main.py` o equivalente. Verifica que workflows corren y reportan resultados (aunque NO bloqueen merge).
- [ ] Merge a main (manual review). Verifica `deploy-beta.yml` se dispara y deploya.
- [ ] Smoke en runtime: `curl <service-url>/health` retorna 200.
- [ ] Forzar PR con CI red: confirmar visualmente que appears red — operator decide no mergear (cultura, no bloqueo automático).

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

## Decisiones documentadas

### GitHub plan: Free + soft enforcement

Org `Viverent` corre en GitHub Free plan (5 seats, 10000 private repos
quota). Decisión: stay Free + soft enforcement strategy. Verificado vía
API 2026-05-10:

```
gh api orgs/Viverent --jq '.plan'
{"name":"free","filled_seats":5,"seats":5,"private_repos":10000}
```

Tabla feature → estrategia Free (verificadas vía `gh api` real):

| Feature Team/Enterprise | Disponible Free? | Reemplazo Free | Estado |
|-------------------------|------------------|----------------|--------|
| Branch protection rules (legacy) | ✗ 403 | NO disponible — soft enforcement | Documentado |
| Branch rulesets | ✗ 403 | Mismo que arriba | Documentado |
| Required PR reviewers (UI gate) | ✗ | Convención + revisión manual | Sin enforcement automático |
| Required status checks (UI gate) | ✗ | Workflows corren pero no bloquean merge | Soft enforcement |
| CODEOWNERS auto-request | ✗ sin branch protection | Archivo informativo de intent | Decorativo en Free |
| Secret scanning private | ✗ "not available" | Trivy detecta credenciales en deps + Semgrep en code | Cobertura parcial |
| Push protection private | ✗ | Pre-commit hook local + Trivy en CI | Soft enforcement |
| Environment required reviewers | ✗ | `trstringer/manual-approval` con issue gate | Funcional |
| CodeQL native private | ✗ requires GHAS | Semgrep + Bandit + Trivy + npm audit | Cobertura ~80% |
| Dependabot auto-merge UI | ✗ | Workflow custom con `dependabot/fetch-metadata` | Funcional |
| Auto-merge feature | ✓ Free | Habilitado per-repo via API | Funcional |
| Workflow write permissions | ✓ Free (org-level enable required) | Org settings → Actions → Workflow permissions | Funcional |
| Dependabot alerts | ✓ Free | UI per-repo o org-level | Funcional |
| Dependabot security updates | ✓ Free | UI per-repo o org-level | Funcional |
| Workload Identity Federation | ✓ Free | S08 setup completo | Operacional |
| Reusable workflows | ✓ Free | Este repo es testimonio | Operacional |

**Costo adicional:** $0/mes.

### Soft enforcement strategy

Sin gates UI, dependemos de:

1. **Workflows informativos** (`ci.yml`, `security-scan.yml`) corren en
   cada PR. Resultados visibles pero NO bloquean merge automático.
   Cultura del equipo: "no mergear con red checks".
2. **Auto-merge selectivo** (`dependabot-auto-merge.yml`) SOLO patches
   Dependabot, vía `gh pr merge --auto` que respeta status checks
   present (no required) — si CI falla, auto-merge no aplica.
3. **Manual approval action** para prod (`trstringer/manual-approval`)
   con issue gate — Free-compatible.
4. **CODEOWNERS** como documentación de ownership (no auto-request en
   Free). Activa enforcement automáticamente si en el futuro upgradean
   a Team.
5. **Push directo a main posible:** cualquiera con write access puede
   pushear sin PR. Mitigaciones:
   - Convention: README repo dice "no push directo, usa PR"
   - CI sigue corriendo y reportando aunque no bloquee
   - Auditoría post-hoc vía `gh api repos/.../events` para detectar violaciones

### Path de upgrade futuro a Team

Costo: $4/seat × 5 seats = **$20/mes**. Migration zero-effort: los
workflows + CODEOWNERS + manual-approval ya están aplicables. Solo se
activan los UI gates al pagar.

### Runner strategy

Free tier (2k min/mes) confirmado suficiente para volumen actual:
- ~2 PR/día × 14 repos × ~5 min/PR = ~2.1k min/mes worst-case.
- Realista (≤1 PR/día): ~1k min/mes, holgura del 50%.

**Self-hosted GCP VM** (e2-medium ~$25/mes ilimitado) queda como
contingencia pre-aprobada si:
- Mensualmente excedemos 1.8k min (90% threshold).
- Empezamos a tener queues consistentes (>5 min wait time).

Setup runbook contingencia:
```bash
gcloud compute instances create github-runner-beta \
  --machine-type=e2-medium \
  --zone=us-central1-a \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --project=vr-portal-fb-beta
# Luego: instalar github-actions-runner, registrar al repo/org,
# servicio systemd.
```

---

## Trabajo deferido (no TODO — diferido conscientemente)

| Item | Diferido a | Razón |
|------|-----------|-------|
| **Compose-supergraph automatizado (Cloud Run Job)** | Post Tier 3 onboarding del router | Requiere bucket GCS + job custom + Dockerfile.compose-supergraph + 4 decisiones técnicas. Bootstrap manual con `composed.graphql` committeado funciona hasta entonces. Roadmap completo en sección "Compose-supergraph implementation plan" abajo. |
| **`repository_dispatch` SDL change → router recompose** | Post compose-supergraph automation + bot account creation | Bloqueado por dependencia técnica + decisión governance (crear `viverent-ci-bot` GH account). |
| **Tags semver para reusables (`@v1.0.0`)** | 30 días post Tier 3 verde | Tag prematuro fuerza re-tags si encontramos bugs estructurales. Soak period necesario. |

### Compose-supergraph implementation plan (cuando se desbloquee)

Decisiones tomadas (production-grade picks, registradas):
- **Bucket region:** single us-central1 (`vr-devops-supergraph-beta`).
- **Versionado:** ambos blobs `composed-latest.graphql` (overwrite) + `composed-${git_sha}.graphql` con lifecycle 90 días.
- **Trigger:** dispatch-only desde subgrafos (path filter `app/graphql/**`).
- **SDL fetch auth:** ID token GCP via `gcloud auth print-identity-token` + `roles/run.invoker` en cada subgrafo para SA `sa-compose-supergraph-${env}`.

Recursos a crear:
1. Bucket GCS `vr-devops-supergraph-beta` (us-central1) + lifecycle 90d.
2. SA `sa-compose-supergraph-beta` con roles: `storage.objectAdmin` sobre el bucket + `run.invoker` sobre 10 subgrafos.
3. Cloud Run Job `compose-supergraph-beta` con VPC connector + imagen Docker custom.
4. `vr-devops/Dockerfile.compose-supergraph` con `rover` CLI + `compose.sh`.
5. `deploy-router.yml` extendido con steps trigger job + download blob.

Esfuerzo estimado: 2-3 horas trabajo.

### Bot account requirements (cuando se cree)

- Email dedicado: `viverent-ci-bot@<dominio>` o Gmail+ alias.
- Agregado a org Viverent como member (no admin).
- Fine-grained PAT con scope:
  - Repository access: solo `Viverent/portal-inversionistas-api`.
  - Permissions: `Actions: read+write`, `Contents: read`.
  - Expiration: 1 año, renovación documentada en runbook.
- Almacenado como org secret `PAT_FOR_DISPATCH`, visible solo para 10 ms-* repos.
