#!/usr/bin/env bash
# Runs on an EC2 instance through SSM Run Command: verify IMAGE's signature,
# switch the backend container to it, health-check it, and roll back to the
# previous image on failure. The pull and each health check are bounded so the
# swap always finishes inside the command's execution timeout.
set -euo pipefail

: "${IMAGE:?IMAGE is required, e.g. <registry>/p4-backend@sha256:<digest>}"
: "${COSIGN_IDENTITY_REGEXP:?COSIGN_IDENTITY_REGEXP is required: the signer identity the image must carry}"
NAME="${NAME:-p4-backend}"
PORT="${PORT:-8080}"
ENV_FILE="${ENV_FILE:-/etc/p4-backend.env}"
STATE_FILE="${STATE_FILE:-/var/lib/p4-backend/current-image}"
PULL_TIMEOUT="${PULL_TIMEOUT:-180}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
COSIGN_OIDC_ISSUER="${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
HEALTH_URL="http://127.0.0.1:${PORT}/healthz"

registry="${IMAGE%%/*}"
previous=$(cat "$STATE_FILE" 2>/dev/null || true)

env_args=()
[ -f "$ENV_FILE" ] && env_args=(--env-file "$ENV_FILE")

start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --restart unless-stopped --init \
    ${env_args[@]+"${env_args[@]}"} -p "${PORT}:3000" "$1" >/dev/null
}

healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  until curl -fs --max-time 2 -o /dev/null "$HEALTH_URL"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

if [[ "$registry" == *.amazonaws.com ]]; then
  region=$(cut -d. -f4 <<<"$registry")
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
fi

cosign verify --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
  --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" "$IMAGE" >/dev/null
echo "signature verified for $IMAGE"

timeout "$PULL_TIMEOUT" docker pull "$IMAGE"

if start "$IMAGE" && healthy; then
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$IMAGE" >"$STATE_FILE"
  docker image prune -af --filter "until=168h" >/dev/null || true
  echo "deployed $IMAGE"
  exit 0
fi

echo "start or health check failed for $IMAGE" >&2
if [ -n "$previous" ]; then
  if start "$previous" && healthy; then
    echo "rolled back to $previous" >&2
  else
    echo "rollback to $previous is unhealthy" >&2
  fi
fi
exit 1
