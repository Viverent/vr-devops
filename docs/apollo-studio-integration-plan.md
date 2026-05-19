# Plan Fase B — Apollo Studio integration (Federation v2 + Uplink + rover CI/CD)

Estado: documentado, NO ejecutado todavía. Sesión dedicada futura.

## Decisiones tomadas

- Schema source: endpoint `/internal/schema` en cada ms-*-api (extract en runtime).
- Cosmo Router: skip. Bypass actual cliente WS direct a ms-tickets-api se mantiene para subscriptions.
- Variants: `viverent-supergraph@dev`, `@beta`, `@main`.

## Pre-requisitos verificados

- Apollo Studio Developer plan activo.
- 3 graph API keys ya en GCP Secret Manager: `dev_apollo_key`, `beta_apollo_key`, `prod_apollo_key`.
- 3 variants creadas en Studio con placeholder SDL.
- Apollo Router 1.52 OSS deployado en los 3 envs (file-based actualmente).

## B.1 — Subgrafos: agregar `/internal/schema` endpoint + Federation v2 directives

Por cada `ms-*-api` (10 repos):

### Endpoint `/internal/schema`

```python
# este endpoint expone el SDL de Strawberry y sirve para rover subgraph publish
from fastapi import APIRouter, Response

internal_router = APIRouter(prefix="/internal", include_in_schema=False)

@internal_router.get("/schema", response_class=Response)
def get_graphql_schema() -> Response:
    from app.graphql.schema import schema
    return Response(content=str(schema), media_type="text/plain")
```

Registrar en `main.py` con HMAC auth check (mismo patrón que `/internal/pubsub/*`).

### Federation v2 directives

Cada subgraph schema Strawberry agregar:

```python
schema = strawberry.federation.Schema(
    query=Query,
    mutation=Mutation,
    enable_federation_2=True,
    schema_directives=[
        strawberry.federation.Link(
            url="https://specs.apollo.dev/federation/v2.5",
            import_=["@key", "@shareable", "@external", "@override", "@inaccessible", "@tag"],
        ),
    ],
)
```

Auditar entities + value types:
- `@key(fields="id")` en entities.
- `@key(fields="id", resolvable=False)` en stubs cross-subgraph.
- `@shareable` en value types compartidos.
- `@external` + `@provides` + `@requires` en field dependencies.

## B.2 — GitHub Environment Secrets (42 entries)

Por cada repo caller (14) × cada environment (dev/beta/prod):

```bash
for repo in 10_ms_api 3_uis router; do
  for env in dev beta prod; do
    apollo_key_value=$(gcloud secrets versions access latest --secret=${env}_apollo_key --project=vr-portal-fb${env_suffix})
    gh secret set APOLLO_KEY --env "$env" --repo "Viverent/$repo" --body "$apollo_key_value"
  done
done
```

## B.3 — vr-devops/ci-backend.yml: `rover subgraph check` on PR

Agregar input `subgraph_name` + step:

```yaml
- name: rover_install
  if: github.event_name == 'pull_request'
  run: |
    curl -sSL https://rover.apollo.dev/nix/latest | sh -s -- --elv2-license=accept
    echo "$HOME/.rover/bin" >> $GITHUB_PATH

- name: rover_subgraph_check
  if: github.event_name == 'pull_request'
  env:
    APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
  run: |
    # extract schema from container build local
    docker build -t ms-svc-temp .
    docker run --rm ms-svc-temp python -c "from app.graphql.schema import schema; print(schema)" > /tmp/schema.graphql
    rover subgraph check viverent-supergraph@dev \
      --name "${{ inputs.subgraph_name }}" \
      --schema /tmp/schema.graphql
```

## B.4 — vr-devops/deploy-microservice.yml: `rover subgraph publish` post-deploy

Agregar input `subgraph_name` + step después de smoke validation:

```yaml
- name: rover_subgraph_publish
  env:
    APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
  run: |
    # extract SDL desde service running via endpoint internal HMAC
    SCHEMA=$(curl -sf -H "X-Internal-Auth: ${{ secrets.INTERNAL_HMAC_HEADER }}" \
      "${{ steps.cfg.outputs.service_url }}/internal/schema")
    echo "$SCHEMA" > /tmp/schema.graphql
    VARIANT="${{ inputs.env == 'prod' && 'main' || inputs.env }}"
    rover subgraph publish "viverent-supergraph@$VARIANT" \
      --name "${{ inputs.subgraph_name }}" \
      --routing-url "${{ steps.cfg.outputs.service_url }}/graphql" \
      --schema /tmp/schema.graphql
```

Mapping env→variant:
- env=dev → @dev
- env=beta → @beta
- env=prod → @main

## B.5 — Router Uplink migration

### Cambios en `portal-inversionistas-api`

`Dockerfile.router`:
```dockerfile
# este Dockerfile sirve para todos los envs (dev/beta/prod) - Uplink consume schema dinamicamente
FROM ghcr.io/apollographql/router:v1.52.0

WORKDIR /app

COPY router.yaml /app/router.yaml

EXPOSE 4000

ENTRYPOINT ["/dist/router", "--config", "/app/router.yaml"]
```

Borrar:
- `Dockerfile.router.beta`
- `Dockerfile.router.dev`
- `supergraph.graphql`
- `supergraph.beta.graphql`
- `supergraph.dev.graphql`
- `supergraph.yaml`
- `supergraph.beta.yaml`
- `supergraph.dev.yaml`
- `supergraph.prod.yaml`
- `supergraph.graphql.bak.20260508`

### Cambios en `vr-devops/.github/workflows/deploy-router.yml`

Agregar env vars al Cloud Run deploy del router:
```bash
gcloud run services replace --service=apollo-router${SVC_SUFFIX} \
  --set-env-vars="APOLLO_GRAPH_REF=viverent-supergraph@${VARIANT},APOLLO_UPLINK_POLL_INTERVAL=10s,APOLLO_INTROSPECTION=false" \
  --set-secrets="APOLLO_KEY=${SECRET_PREFIX}apollo_key:latest"
```

Mapping env→variant (mismo que B.4).

## B.6 — Notifications schema_change en Studio UI

Per variant:
- @main: Slack webhook a canal `#vr-graphql-changes` (URL TBD usuario)
- @beta: Slack mismo canal
- @dev: ninguno (ruido)

User configura via UI Studio. No automatizable via API públicamente disponible.

## B.7 — Schema linting reglas

Configurar en Studio UI → Checks → Configuration → Linter:
- `FIELD_NAMES_SHOULD_BE_CAMEL_CASE` (warn)
- `TYPES_SHOULD_BE_PASCAL_CASE` (warn)
- `OBJECT_PREFIX` (ignore — patrón Strawberry sufijo `Type` aceptado)
- `DESCRIPTION_FOR_DEPRECATED` (error)

Solo flagea diff vs schema publicado.

## B.8 — Validación E2E

Per env:
1. `rover subgraph publish` succeed para cada subgraph (10 publicaciones por env = 30 total).
2. Apollo Studio composition status = green per variant.
3. Router pickup new SDL en ≤10s tras publish (verify via revision NO rota Cloud Run + log "loaded supergraph").
4. Query test desde Apollo Studio Explorer per variant.
5. Operations analytics aparecen tras 5-10 min tráfico real.
6. Schema check on PR bloquea PR si composition error.

## B.9 — Cutover orden propuesto

1. Implementar B.1 (`/internal/schema` + Federation v2) en `ms-tickets-api` solo → push dev → smoke
2. Si OK, batch los 9 ms-*-api restantes
3. B.2 Apollo keys a GitHub Environment Secrets (42 entries) — automatizable
4. B.3 + B.4 vr-devops reusables update
5. Trigger 10 deploy dev → validate rover publish funciona per subgraph en variant @dev
6. PR vr-devops cambios a 14 callers beta (28 PRs nuevos)
7. Validate variants @beta poblados
8. PR cambios a main → validate @main poblado
9. B.5 router Uplink: deploy dev primero, validate router picks up @dev, después beta + main
10. Cleanup hand-built supergraph files

## Duración estimada

- B.1 (10 ms-*-api): 3-4 horas
- B.2 (secrets): 30 min
- B.3 + B.4 (reusables): 2 horas
- B.5 (router): 2 horas
- Validación + cutover beta+main: 3-4 horas

Total: ~10-12 horas autopilot.

## Riesgos identificados

1. **`/internal/schema` endpoint security**: debe estar protegido con HMAC interno. NO exponer públicamente.
2. **Strawberry export schema**: el `str(schema)` Strawberry genera SDL pero la composición Federation v2 puede diferir del schema published actual hand-built. Comparar diff antes de cutover.
3. **Variant @main publish fail breaks production**: si composition error post-publish, router OSS sigue con last-good Uplink, pero schema checks bloquean futuros deploys. Tener rollback rover supergraph fetch+revert.
4. **rover CLI version pinning**: usar `--profile-version` específica en GH Actions para reproducibilidad.
5. **APOLLO_KEY scope**: cada variant tiene API key separada. Mezclar variant + key incorrecto = publish fail.

## Pre-cutover checklist

- [ ] Apollo Studio Developer plan activo y billing OK
- [ ] Las 3 variants existen con SDL placeholder
- [ ] APOLLO_KEY values verificables en GCP Secret Manager
- [ ] Composition Federation v2 funcional en cada subgraph local
- [ ] router.yaml soporta env var override (verificar `${env.APOLLO_KEY}` accept)
- [ ] DNS/Slack webhook listo para notifications (opcional)

---

NO ejecutar autopilot completo sin validar paso a paso. Empezar con `ms-tickets-api` solo, smoke, después escalar.
