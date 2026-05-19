#!/usr/bin/env bash
set -euo pipefail

# dispara workflow_dispatch en GH API usando PAT desde env var
GH_PAT="${GH_PAT:?GH_PAT required}"
GH_REPO="${GH_REPO:?GH_REPO required (ej Viverent/vr-devops)}"
GH_WORKFLOW="${GH_WORKFLOW:?GH_WORKFLOW required (ej sql-refresh-beta.yml)}"
GH_REF="${GH_REF:-main}"
GH_INPUT_CONFIRM="${GH_INPUT_CONFIRM:-YES}"

curl -sSf -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GH_PAT" \
  "https://api.github.com/repos/${GH_REPO}/actions/workflows/${GH_WORKFLOW}/dispatches" \
  -d "{\"ref\":\"${GH_REF}\",\"inputs\":{\"confirm\":\"${GH_INPUT_CONFIRM}\"}}"

echo "[$(date -Iseconds)] dispatched ${GH_WORKFLOW} in ${GH_REPO}@${GH_REF}"
