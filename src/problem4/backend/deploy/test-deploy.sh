#!/usr/bin/env bash
# Exercises deploy.sh against the local Docker daemon: a healthy image deploys
# and is recorded; a broken image fails its health check and the previous image
# comes back; an image whose signature check fails is refused before the running
# container is touched. Registry login, pull and cosign are stubbed, so no
# account or network is needed and Sigstore itself is not exercised.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
name=p4-deploy-test
port="${TEST_PORT:-18080}"
repo=123456789012.dkr.ecr.us-east-1.amazonaws.com/p4-backend
identity='^https://github.com/example/repo/\.github/workflows/_container\.yml@refs/heads/main$'

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker rmi -f "$repo:good" "$repo:bad" "$repo:unsigned" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
version() { curl -fs "http://localhost:$port/api/version" || true; }

docker build -q --build-arg APP_VERSION=good -t "$repo:good" "$here/.." >/dev/null
printf 'FROM alpine:3\nCMD ["sleep","600"]\n' | docker build -q -t "$repo:bad" - >/dev/null
docker build -q --build-arg APP_VERSION=unsigned -t "$repo:unsigned" "$here/.." >/dev/null

real_docker=$(command -v docker)
mkdir -p "$work/bin"
printf '#!/bin/sh\necho stub-token\n' >"$work/bin/aws"
cat >"$work/bin/docker" <<EOF
#!/bin/sh
case "\$1" in
  login) cat >/dev/null; exit 0 ;;
  pull) exit 0 ;;
esac
exec "$real_docker" "\$@"
EOF
# The cosign stub rejects the :unsigned image and any other signer identity.
cat >"$work/bin/cosign" <<EOF
#!/bin/sh
case "\$*" in
  *":unsigned") echo "no matching signatures" >&2; exit 1 ;;
  *"--certificate-identity-regexp $identity "*) exit 0 ;;
esac
echo "unexpected identity: \$*" >&2
exit 1
EOF
command -v timeout >/dev/null || printf '#!/bin/sh\nshift\nexec "$@"\n' >"$work/bin/timeout"
chmod +x "$work"/bin/*
export PATH="$work/bin:$PATH" NAME="$name" PORT="$port" STATE_FILE="$work/current-image" ENV_FILE="$work/absent" \
  HEALTH_TIMEOUT=6 COSIGN_IDENTITY_REGEXP="$identity"

IMAGE="$repo:good" "$here/deploy.sh" >"$work/good.log" 2>&1 || { cat "$work/good.log" >&2; fail "the healthy image did not deploy"; }
[ "$(cat "$STATE_FILE")" = "$repo:good" ] || fail "the state file does not record the healthy image"
[ "$(version)" = '{"version":"good"}' ] || fail "the healthy image is not serving"
pass "a healthy image deploys and is recorded"

if IMAGE="$repo:bad" "$here/deploy.sh" >"$work/bad.log" 2>&1; then
  fail "the broken image was reported as deployed"
fi
grep -q "rolled back to $repo:good" "$work/bad.log" || { cat "$work/bad.log" >&2; fail "deploy.sh did not report a rollback"; }
[ "$(cat "$STATE_FILE")" = "$repo:good" ] || fail "the state file changed after a failed deploy"
[ "$(version)" = '{"version":"good"}' ] || fail "the previous image was not restored"
pass "a broken image fails its health check and the previous image is restored"

started=$(docker inspect -f '{{.State.StartedAt}}' "$name")
if IMAGE="$repo:unsigned" "$here/deploy.sh" >"$work/unsigned.log" 2>&1; then
  fail "the image with a failed signature check was reported as deployed"
fi
grep -q "no matching signatures" "$work/unsigned.log" || { cat "$work/unsigned.log" >&2; fail "deploy.sh did not stop at the signature check"; }
[ "$(docker inspect -f '{{.State.StartedAt}}' "$name")" = "$started" ] || fail "the running container was replaced"
[ "$(version)" = '{"version":"good"}' ] || fail "the running image changed after a refused signature"
pass "an image whose signature check fails is refused and the running container is untouched"
