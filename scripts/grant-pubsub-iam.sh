#!/usr/bin/env bash

set -euo pipefail

ENV_NAME="${1:?uso: grant-pubsub-iam.sh <beta|dev|prod>}"

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

TICKETS_SA="sa-ms-tickets${SA_SUFFIX}@${PROJECT_ID}.iam.gserviceaccount.com"
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
