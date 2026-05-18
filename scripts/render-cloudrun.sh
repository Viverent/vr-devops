#!/usr/bin/env bash
# Sprint 05 — render-cloudrun.sh
# Genera YAML Knative-style completo para `gcloud run services replace`
# o `gcloud run jobs replace`. Usa envsubst con allowlist explícita
# (sin allowlist el comando expande $PATH/$PORT/$HOME del shell).
#
# Uso: bash scripts/render-cloudrun.sh <env> <svc> [--job]
#   <env>: beta|prod
#   <svc>: subgrafo (core, identity, ...) | auth-validator | apollo-router
#   --job: genera Job YAML para alembic migrate (en lugar de Service)
#
# Output: /tmp/cloudrun-<svc>-<env>.yaml (o /tmp/cloudjob-<svc>-<env>.yaml)

set -euo pipefail

usage() {
  echo "usage: $0 <env> <svc> [--job]" >&2
  exit 1
}

[ $# -ge 2 ] || usage

ENV_NAME="$1"
SVC="$2"
MODE="service"
[ "${3:-}" = "--job" ] && MODE="job"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/infra/env/${ENV_NAME}.env"
# shellcheck disable=SC1090
source "$ENV_FILE"

# ── Resolve image (build-image.sh deja el último tag en /tmp) ────────
IMAGE_FILE="/tmp/last-image-${SVC}-${ENV_NAME}.txt"
if [ -f "$IMAGE_FILE" ]; then
  export IMAGE="$(cat "$IMAGE_FILE")"
else
  echo "warn: $IMAGE_FILE no existe — corre scripts/build-image.sh primero" >&2
  exit 1
fi

# ── Per-service tuning ───────────────────────────────────────────────
# Defaults
export INGRESS="$DEFAULT_INGRESS"
export VPC_EGRESS="$DEFAULT_VPC_EGRESS"
export TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
export CONCURRENCY="$DEFAULT_CONCURRENCY"
export MIN_SCALE="$DEFAULT_MIN_SCALE"
export MAX_SCALE="$DEFAULT_MAX_SCALE"
export CPU="$DEFAULT_CPU"
export MEMORY="$DEFAULT_MEMORY"
# CPU throttling: por defecto Cloud Run congela el CPU de la instancia
# fuera del procesamiento de un request. Para SSE long-lived (ms-tickets)
# eso impide que pubsub.listen() procese mensajes Redis mientras la
# conexion esta idle entre eventos. "true" = comportamiento default.
export CPU_THROTTLING="true"

case "$SVC" in
  tickets)
    export VPC_EGRESS="$TICKETS_VPC_EGRESS"
    export TIMEOUT_SECONDS="$TICKETS_TIMEOUT_SECONDS"
    export MIN_SCALE="$TICKETS_MIN_SCALE"
    export CONCURRENCY="$TICKETS_CONCURRENCY"
    export INGRESS="$TICKETS_INGRESS"
    # SSE necesita CPU asignado siempre para procesar eventos Redis
    # mientras la conexion esta abierta sin trafico de request.
    export CPU_THROTTLING="false"
    ;;
  auth-validator)
    export INGRESS="$AUTH_VALIDATOR_INGRESS"
    export MEMORY="$AUTH_VALIDATOR_MEMORY"
    # auth-validator (gateway) llama a apollo-router (ingress=internal,
    # hostname *.run.app IP publica). VPC_EGRESS=private-ranges-only no
    # routea hostnames publicos por VPC connector y las requests no
    # alcanzan el target con ingress=internal. all-traffic fuerza que
    # todo egress salga via VPC connector, permitiendo que el ingress
    # check de Cloud Run reconozca la request como interna.
    export VPC_EGRESS="$AUTH_VALIDATOR_VPC_EGRESS"
    export MIN_SCALE="${AUTH_VALIDATOR_MIN_SCALE:-0}"
    ;;
  apollo-router)
    # Router corre en internal; auth-validator lo invoca.
    # Router llama a subgrafos (10 ms-*, todos ingress=internal). Necesita
    # all-traffic via VPC para alcanzar hostnames *.run.app con
    # ingress=internal — mismo razonamiento que auth-validator.
    export INGRESS="internal"
    export VPC_EGRESS="$ROUTER_VPC_EGRESS"
    export MIN_SCALE="${ROUTER_MIN_SCALE:-0}"
    ;;
esac

# ── Service / Job naming ─────────────────────────────────────────────
case "$SVC" in
  apollo-router)
    export SERVICE_NAME="apollo-router${SVC_SUFFIX}"
    export RUNTIME_SA_EMAIL="sa-apollo-router${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    ;;
  auth-validator)
    export SERVICE_NAME="auth-validator${SVC_SUFFIX}"
    export RUNTIME_SA_EMAIL="sa-auth-validator${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    ;;
  *)
    if [ "$MODE" = "job" ]; then
      export JOB_NAME="ms-${SVC}-migrate${SVC_SUFFIX}"
      # Jobs migrate beta usan SA compartida sa-cloud-run-jobs-beta
      # (heredado de bootstrap_beta.sh); prod heredará la misma decisión.
      export RUNTIME_SA_EMAIL="sa-cloud-run-jobs${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    else
      export SERVICE_NAME="ms-${SVC}-api${SVC_SUFFIX}"
      export RUNTIME_SA_EMAIL="sa-ms-${SVC}${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    fi
    ;;
esac

# ── ENV_BLOCK (env vars + secret refs) ───────────────────────────────
build_env_block() {
  local out="          env:"
  out+=$'\n'"            - name: ENV"$'\n'"              value: \"${ENV}\""
  out+=$'\n'"            - name: GCP_PROJECT_ID"$'\n'"              value: \"${PROJECT_ID}\""
  out+=$'\n'"            - name: LOG_LEVEL"$'\n'"              value: \"${DEFAULT_LOG_LEVEL}\""
  # AUTH_MODE: subgrafos reciben requests del router con headers
  # X-Firebase-UID/X-Person-Id inyectados upstream (internal_headers).
  # auth-validator es el front-end gateway: valida Firebase Bearer del
  # browser y EMITE los headers internos → necesita firebase mode.
  local auth_mode="${DEFAULT_AUTH_MODE}"
  if [ "$SVC" = "auth-validator" ]; then
    auth_mode="firebase"
  fi
  out+=$'\n'"            - name: AUTH_MODE"$'\n'"              value: \"${auth_mode}\""
  out+=$'\n'"            - name: DB_POOL_SIZE"$'\n'"              value: \"${DEFAULT_DB_POOL_SIZE}\""
  out+=$'\n'"            - name: DB_POOL_MAX_OVERFLOW"$'\n'"              value: \"${DEFAULT_DB_POOL_MAX_OVERFLOW}\""

  case "$SVC" in
    catalog|contracts|identity|persons|rentals|sales|tickets)
      out+=$'\n'"            - name: PUBSUB_AUDIT_TOPIC"$'\n'"              value: \"${PUBSUB_AUDIT_TOPIC}\""
      ;;
  esac

  case "$SVC" in
    persons)
      out+=$'\n'"            - name: GCS_DOCUMENTS_BUCKET"$'\n'"              value: \"${GCS_DOCUMENTS_BUCKET}\""
      ;;
    tickets)
      out+=$'\n'"            - name: ATTACHMENT_BUCKET"$'\n'"              value: \"${ATTACHMENT_BUCKET}\""
      out+=$'\n'"            - name: MS_IDENTITY_URL"$'\n'"              value: \"${MS_IDENTITY_URL:-}\""
      out+=$'\n'"            - name: MS_CONTRACTS_URL"$'\n'"              value: \"${MS_CONTRACTS_URL:-}\""
      out+=$'\n'"            - name: MS_PERSONS_URL"$'\n'"              value: \"${MS_PERSONS_URL:-}\""
      # ms-tickets es el unico subgrafo con ingress=all (SSE necesita
      # llamada directa desde browser sin pasar por router/auth-validator);
      # por eso CORS_ORIGINS aplica solo aqui dentro de los subgrafos.
      out+=$'\n'"            - name: CORS_ORIGINS"$'\n'"              value: \"${CORS_ORIGINS}\""
      out+=$'\n'"            - name: RESEND_API_KEY"
      out+=$'\n'"              valueFrom:"
      out+=$'\n'"                secretKeyRef:"
      out+=$'\n'"                  key: latest"
      out+=$'\n'"                  name: ${SECRET_PREFIX}resend_api_key"
      ;;
    auth-validator)
      out+=$'\n'"            - name: APOLLO_ROUTER_URL"$'\n'"              value: \"${APOLLO_ROUTER_URL:-}/graphql\""
      out+=$'\n'"            - name: MS_IDENTITY_GRAPHQL_URL"$'\n'"              value: \"${MS_IDENTITY_URL:-}/graphql\""
      out+=$'\n'"            - name: CORS_ORIGINS"$'\n'"              value: \"${CORS_ORIGINS}\""
      out+=$'\n'"            - name: APOLLO_INTROSPECTION"$'\n'"              value: \"false\""
      out+=$'\n'"            - name: APOLLO_SANDBOX"$'\n'"              value: \"false\""
      out+=$'\n'"            - name: FIREBASE_SERVICE_ACCOUNT_PATH"$'\n'"              value: \"/secrets/firebase-service-account.json\""
      out+=$'\n'"            - name: INTERNAL_SIGNING_ENABLED"$'\n'"              value: \"true\""
      out+=$'\n'"            - name: FAIL_CLOSED_ON_IDENTITY_UNREACHABLE"$'\n'"              value: \"true\""
      ;;
  esac

  # Secrets (database_url + redis + hmac) — solo subgrafos
  if [ "$SVC" != "auth-validator" ] && [ "$SVC" != "apollo-router" ]; then
    out+=$'\n'"            - name: DATABASE_URL"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}ms_${SVC}_database_url"
    out+=$'\n'"            - name: REDIS_URL"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}redis_url"
    out+=$'\n'"            - name: INTERNAL_HMAC_SECRET"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}internal_hmac_secret"
  fi

  if [ "$SVC" = "auth-validator" ]; then
    out+=$'\n'"            - name: FIREBASE_PROJECT_ID"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}firebase_project_id"
    out+=$'\n'"            - name: INTERNAL_HMAC_SECRET"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}internal_hmac_secret"
    out+=$'\n'"            - name: REDIS_URL"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}redis_url"
  fi

  # ms-identity envia emails transaccionales (password reset) via Resend.
  # Sin RESEND_API_KEY el flow falla silenciosamente — wire obligatorio.
  # PORTAL_URL es el continueUrl que Firebase Identity Toolkit valida
  # contra authorizedDomains del proyecto Firebase. Sin esta var cae al
  # default de config.py ("https://app.viverent.com"); en beta ese
  # dominio NO esta allowlisted → UNAUTHORIZED_DOMAIN → catch en
  # mutations.py:563 swallows → email nunca sale (confirmado 2026-05-12).
  if [ "$SVC" = "identity" ]; then
    out+=$'\n'"            - name: RESEND_API_KEY"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}resend_api_key"
    out+=$'\n'"            - name: PORTAL_URL"
    out+=$'\n'"              value: \"${PORTAL_URL_IDENTITY}\""
  fi

  printf '%s' "$out"
}

build_volume_mounts_block() {
  if [ "$SVC" = "auth-validator" ]; then
    cat <<'EOF'
          volumeMounts:
            - name: firebase-sa
              mountPath: /secrets
              readOnly: true
EOF
  fi
}

build_volumes_block() {
  if [ "$SVC" = "auth-validator" ]; then
    cat <<EOF
      volumes:
        - name: firebase-sa
          secret:
            secretName: ${SECRET_PREFIX}firebase_service_account
            items:
              - key: latest
                path: firebase-service-account.json
EOF
  fi
}

# MIN_SCALE_ANNOT: omit annotation entirely when MIN_SCALE=0 (matches
# Cloud Run state real — provider no incluye annotation cuando default)
if [ "$MIN_SCALE" = "0" ]; then
  export MIN_SCALE_ANNOT=""
else
  export MIN_SCALE_ANNOT="        autoscaling.knative.dev/minScale: \"${MIN_SCALE}\""
fi

ENV_BLOCK_RAW="$(build_env_block)"
# Job YAML tiene un nivel extra de anidamiento (spec.template.spec.template.spec)
# por encima del container. ENV_BLOCK escrito con 10 espacios para Service;
# para Job re-indentar +4 espacios.
if [ "$MODE" = "job" ]; then
  export ENV_BLOCK="$(echo "$ENV_BLOCK_RAW" | sed 's/^/    /')"
else
  export ENV_BLOCK="$ENV_BLOCK_RAW"
fi
export VOLUME_MOUNTS_BLOCK="$(build_volume_mounts_block)"
export VOLUMES_BLOCK="$(build_volumes_block)"

# ── Render via envsubst con allowlist ────────────────────────────────
ALLOWLIST="$(cat "${REPO_ROOT}/infra/cloud-run-templates/allowlist.txt")"

if [ "$MODE" = "job" ]; then
  TEMPLATE="${REPO_ROOT}/infra/cloud-run-templates/job.template.yaml"
  OUT="/tmp/cloudjob-${SVC}-${ENV_NAME}.yaml"
else
  TEMPLATE="${REPO_ROOT}/infra/cloud-run-templates/subgraph.template.yaml"
  OUT="/tmp/cloudrun-${SVC}-${ENV_NAME}.yaml"
fi

envsubst "$ALLOWLIST" < "$TEMPLATE" > "$OUT"
echo "$OUT"
