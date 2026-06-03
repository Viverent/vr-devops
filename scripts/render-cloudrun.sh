#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 <env> <svc> [--job]" >&2
  echo "  <env>: beta|dev|prod" >&2
  echo "  <svc>: subgrafo (core, identity, ...) | auth-validator | apollo-router" >&2
  echo "  --job: genera Job YAML para alembic migrate (en lugar de Service)" >&2
  exit 1
}

[ $# -ge 2 ] || usage

ENV_NAME="$1"
SVC="$2"
MODE="service"
[ "${3:-}" = "--job" ] && MODE="job"

case "$ENV_NAME" in
  beta|dev|prod) ;;
  *) echo "error: env invalido '$ENV_NAME' (valid: beta|dev|prod)" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/infra/env/${ENV_NAME}.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: no existe $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

IMAGE_FILE="/tmp/last-image-${SVC}-${ENV_NAME}.txt"
if [ -f "$IMAGE_FILE" ]; then
  export IMAGE="$(cat "$IMAGE_FILE")"
else
  echo "warn: $IMAGE_FILE no existe — corre scripts/build-image.sh primero" >&2
  exit 1
fi

export INGRESS="$DEFAULT_INGRESS"
export VPC_EGRESS="$DEFAULT_VPC_EGRESS"
export TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
export CONCURRENCY="$DEFAULT_CONCURRENCY"
export MIN_SCALE="$DEFAULT_MIN_SCALE"
export MAX_SCALE="$DEFAULT_MAX_SCALE"
export CPU="$DEFAULT_CPU"
export MEMORY="$DEFAULT_MEMORY"
export CPU_THROTTLING="true"

case "$SVC" in
  tickets)
    export VPC_EGRESS="$TICKETS_VPC_EGRESS"
    export TIMEOUT_SECONDS="$TICKETS_TIMEOUT_SECONDS"
    export MIN_SCALE="$TICKETS_MIN_SCALE"
    export CONCURRENCY="$TICKETS_CONCURRENCY"
    export INGRESS="$TICKETS_INGRESS"
    export CPU_THROTTLING="false"
    ;;
  auth-validator)
    export INGRESS="$AUTH_VALIDATOR_INGRESS"
    export MEMORY="$AUTH_VALIDATOR_MEMORY"
    export VPC_EGRESS="$AUTH_VALIDATOR_VPC_EGRESS"
    export MIN_SCALE="${AUTH_VALIDATOR_MIN_SCALE:-0}"
    ;;
  apollo-router)
    export INGRESS="internal"
    export VPC_EGRESS="$ROUTER_VPC_EGRESS"
    export MIN_SCALE="${ROUTER_MIN_SCALE:-0}"
    # Sprint 1 hotfix (2026-05-28) — override memoria + CPU del router.
    # Parsing de bodies grandes (uploads de attachments base64) con 512Mi
    # provocaba OOM/restart bajo carga (502/503 "malformed response"). Bump
    # vía ROUTER_MEMORY / ROUTER_CPU en cada env file. Fallback al DEFAULT.
    export MEMORY="${ROUTER_MEMORY:-$DEFAULT_MEMORY}"
    export CPU="${ROUTER_CPU:-$DEFAULT_CPU}"
    ;;
  identity)
    export MIN_SCALE="${IDENTITY_MIN_SCALE:-0}"
  ;;
  persons)
    export MIN_SCALE="${PERSONS_MIN_SCALE:-0}"
    # all-traffic: ms-persons resuelve el operador contra ms-identity
    # (ingress=internal) en el alta on-behalf; private-ranges-only daba 404.
    export VPC_EGRESS="all-traffic"
  ;;
esac

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
      export RUNTIME_SA_EMAIL="sa-cloud-run-jobs${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    else
      export SERVICE_NAME="ms-${SVC}-api${SVC_SUFFIX}"
      export RUNTIME_SA_EMAIL="sa-ms-${SVC}${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
    fi
    ;;
esac

build_env_block() {
  local out="          env:"
  out+=$'\n'"            - name: ENV"$'\n'"              value: \"${ENV}\""
  out+=$'\n'"            - name: GCP_PROJECT_ID"$'\n'"              value: \"${PROJECT_ID}\""
  out+=$'\n'"            - name: LOG_LEVEL"$'\n'"              value: \"${DEFAULT_LOG_LEVEL}\""

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
      out+=$'\n'"            - name: MS_CORE_URL"$'\n'"              value: \"${MS_CORE_URL:-}\""
      out+=$'\n'"            - name: MS_IDENTITY_URL"$'\n'"              value: \"${MS_IDENTITY_URL:-}\""
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

  # STAGING_DATABASE_URL: solo persons y finance leen la BD staging dedicada
  # de solicitudes de cambio (change_requests), por env desde Secret Manager.
  case "$SVC" in
    persons|finance)
      out+=$'\n'"            - name: STAGING_DATABASE_URL"
      out+=$'\n'"              valueFrom:"
      out+=$'\n'"                secretKeyRef:"
      out+=$'\n'"                  key: latest"
      out+=$'\n'"                  name: ${SECRET_PREFIX}change_requests_database_url"
      ;;
  esac

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

  if [ "$SVC" = "apollo-router" ]; then
    out+=$'\n'"            - name: APOLLO_GRAPH_REF"
    out+=$'\n'"              value: \"${APOLLO_GRAPH_REF}\""
    out+=$'\n'"            - name: APOLLO_UPLINK_POLL_INTERVAL"
    out+=$'\n'"              value: \"10s\""
    out+=$'\n'"            - name: APOLLO_INTROSPECTION"
    out+=$'\n'"              value: \"false\""
    out+=$'\n'"            - name: APOLLO_KEY"
    out+=$'\n'"              valueFrom:"
    out+=$'\n'"                secretKeyRef:"
    out+=$'\n'"                  key: latest"
    out+=$'\n'"                  name: ${SECRET_PREFIX}apollo_key"
  fi

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

if [ "$MIN_SCALE" = "0" ]; then
  export MIN_SCALE_ANNOT=""
else
  export MIN_SCALE_ANNOT="        autoscaling.knative.dev/minScale: \"${MIN_SCALE}\""
fi

ENV_BLOCK_RAW="$(build_env_block)"
if [ "$MODE" = "job" ]; then
  export ENV_BLOCK="$(echo "$ENV_BLOCK_RAW" | sed 's/^/    /')"
else
  export ENV_BLOCK="$ENV_BLOCK_RAW"
fi
export VOLUME_MOUNTS_BLOCK="$(build_volume_mounts_block)"
export VOLUMES_BLOCK="$(build_volumes_block)"

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
