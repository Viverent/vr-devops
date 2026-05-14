#!/usr/bin/env bash
# Otorga roles/pubsub.publisher a las service accounts de los subgrafos
# que publican eventos a topics Cloud Pub/Sub dedicados.
#
# Por que existe: los topics se crean en el bootstrap del proyecto, pero
# el IAM binding publisher por-SA no estaba versionado. ms-tickets-api
# publica a `ms-tickets-events-<env>` (topic dedicado, ver PR #16 de
# ms-tickets-api) y sin el binding las mutations logean:
#   publish_envelope tickets_topic falló ... 403 IAM_PERMISSION_DENIED
#   pubsub.topics.publish
# El realtime (Redis pub/sub) NO depende de esto, pero el audit/event
# stream cross-service si.
#
# Idempotente: `gcloud pubsub topics add-iam-policy-binding` no duplica
# bindings — re-ejecutar es seguro.
#
# Uso:
#   scripts/grant-pubsub-iam.sh beta
#   scripts/grant-pubsub-iam.sh prod
#
# Requiere: gcloud autenticado con permiso pubsub.topics.setIamPolicy
# en el proyecto target (rol Owner o Pub/Sub Admin).

set -euo pipefail

ENV_NAME="${1:?uso: grant-pubsub-iam.sh <beta|prod>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../infra/env/${ENV_NAME}.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: no existe ${ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# SA runtime de ms-tickets — mismo naming que render-cloudrun.sh:
#   sa-ms-<svc><SA_SUFFIX>@<PROJECT_ID>.iam.gserviceaccount.com
TICKETS_SA="sa-ms-tickets${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"

# Topic dedicado de ms-tickets. SVC_SUFFIX = -beta | -prod.
TICKETS_TOPIC="ms-tickets-events${SVC_SUFFIX}"

echo "── grant-pubsub-iam (${ENV_NAME}) ──────────────────────────────"
echo "  project : ${PROJECT_ID}"
echo "  topic   : ${TICKETS_TOPIC}"
echo "  member  : serviceAccount:${TICKETS_SA}"
echo "  role    : roles/pubsub.publisher"
echo ""

gcloud pubsub topics add-iam-policy-binding "${TICKETS_TOPIC}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${TICKETS_SA}" \
  --role="roles/pubsub.publisher"

echo ""
echo "OK — ${TICKETS_SA} puede publicar en ${TICKETS_TOPIC}"
