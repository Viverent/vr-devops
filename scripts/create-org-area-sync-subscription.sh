#!/usr/bin/env bash
#
# Crea la suscripción Pub/Sub Push que sincroniza la proyección
# `ticket_areas` de ms-tickets con el catálogo canónico `org_areas` de
# ms-identity (Fase 1 — feature Áreas).
#
# ms-identity publica `identity.org_area_changed` al topic de auditoría
# cross-service (PUBSUB_AUDIT_TOPIC). Esta suscripción, filtrada por ese
# event_type, entrega el envelope vía HTTP Push al endpoint
# `/internal/pubsub/identity-events` de ms-tickets.
#
# Idempotente: si la suscripción ya existe, no la recrea.

set -euo pipefail

ENV_NAME="${1:?uso: create-org-area-sync-subscription.sh <beta|dev|prod>}"

case "$ENV_NAME" in
  beta|dev|prod) ;;
  *) echo "error: env invalido '$ENV_NAME' (valid: beta|dev|prod)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../infra/env/${ENV_NAME}.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: no existe ${ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

TICKETS_SERVICE="ms-tickets${MS_IMAGE_SUFFIX}${SVC_SUFFIX}"
TICKETS_SA="sa-ms-tickets${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
SUBSCRIPTION="ms-tickets-org-area-sync${SVC_SUFFIX}"

# URL del Cloud Run de ms-tickets — se resuelve en vivo para no hardcodear.
TICKETS_URL="$(gcloud run services describe "${TICKETS_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --format='value(status.url)')"

if [ -z "${TICKETS_URL}" ]; then
  echo "error: no se resolvió la URL de ${TICKETS_SERVICE}" >&2
  exit 1
fi

PUSH_ENDPOINT="${TICKETS_URL}/internal/pubsub/identity-events"

echo "── create-org-area-sync-subscription (${ENV_NAME}) ──────────────"
echo "  project      : ${PROJECT_ID}"
echo "  topic        : ${PUBSUB_AUDIT_TOPIC}"
echo "  subscription : ${SUBSCRIPTION}"
echo "  push endpoint: ${PUSH_ENDPOINT}"
echo "  push auth SA : ${TICKETS_SA}"
echo ""

# La SA que firma el OIDC token del push necesita invoker sobre el
# Cloud Run de ms-tickets para que IAM acepte la entrega.
gcloud run services add-iam-policy-binding "${TICKETS_SERVICE}" \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --member="serviceAccount:${TICKETS_SA}" \
  --role="roles/run.invoker"

if gcloud pubsub subscriptions describe "${SUBSCRIPTION}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "subscription ${SUBSCRIPTION} ya existe — no se recrea."
  exit 0
fi

# Filtro sobre el atributo event_type del envelope — solo entrega
# identity.org_area_changed (el topic de auditoría lleva muchos eventos).
gcloud pubsub subscriptions create "${SUBSCRIPTION}" \
  --project="${PROJECT_ID}" \
  --topic="${PUBSUB_AUDIT_TOPIC}" \
  --push-endpoint="${PUSH_ENDPOINT}" \
  --push-auth-service-account="${TICKETS_SA}" \
  --message-filter='attributes.event_type = "identity.org_area_changed"' \
  --ack-deadline=30 \
  --min-retry-delay=10s \
  --max-retry-delay=600s

echo ""
echo "OK — ${SUBSCRIPTION} entrega identity.org_area_changed a ${PUSH_ENDPOINT}"
