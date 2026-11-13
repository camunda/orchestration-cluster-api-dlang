#!/usr/bin/env bash
# Ask code.dlang.org to fetch the tag that semantic-release just pushed.
#
# Invoked by @semantic-release/exec successCmd. Uses the DUB registry
# "register" / "update" HTTP API. Credentials:
#   DUB_REGISTRY_TOKEN  - token from https://code.dlang.org (account settings)
#
# When the token is absent (forks, first run before the package exists) the
# script no-ops so the release still succeeds. A failed notification is logged
# but never fails the release: the tag is already on GitHub and the registry
# also crawls hooked repositories.
set -euo pipefail

VERSION="${1:-unknown}"
REPO_URL="https://github.com/camunda/orchestration-cluster-api-dlang.git"

if [[ -z "${DUB_REGISTRY_TOKEN:-}" ]]; then
  echo "[notify-dub] DUB_REGISTRY_TOKEN not set — skipping code.dlang.org sync for ${VERSION}." >&2
  exit 0
fi

echo "[notify-dub] Requesting code.dlang.org update for ${REPO_URL} (release ${VERSION})"

response_body="$(mktemp)"
trap 'rm -f "${response_body}"' EXIT

# Prefer update (already registered). Fall back to register on 404.
http_code="$(curl -sS -o "${response_body}" -w '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  -X POST \
  -H "Authorization: Bearer ${DUB_REGISTRY_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'User-Agent: camunda-orchestration-cluster-api-dlang-release (mailto:info@camunda.com)' \
  "https://code.dlang.org/api/packages/update" \
  -d "{\"repository\":{\"kind\":\"github\",\"url\":\"${REPO_URL}\"}}" || echo "000")"

if [[ "${http_code}" == "404" ]]; then
  http_code="$(curl -sS -o "${response_body}" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${DUB_REGISTRY_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'User-Agent: camunda-orchestration-cluster-api-dlang-release (mailto:info@camunda.com)' \
    "https://code.dlang.org/api/packages/register" \
    -d "{\"name\":\"camunda-orchestration-sdk\",\"repository\":{\"kind\":\"github\",\"url\":\"${REPO_URL}\"}}" || echo "000")"
fi

echo "[notify-dub] HTTP ${http_code}: $(cat "${response_body}")" >&2
if [[ "${http_code}" != 2* && "${http_code}" != "409" ]]; then
  echo "[notify-dub] non-fatal: registry did not accept the ping" >&2
fi
