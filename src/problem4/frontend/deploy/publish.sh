#!/usr/bin/env bash
# Publishes a built SPA (DIST_DIR) to S3 behind CloudFront: hashed assets first
# with a one-year immutable cache, then the environment's config.json and
# index.html with no-cache, then invalidates those two paths. Before uploading
# it records the live index.html version, written as previous_index_version=<id>
# to the file named by PUBLISH_STATE when set.
# `publish.sh --restore <version-id>` puts that index.html version back and
# invalidates it, which is the rollback after a failed smoke test.
# DRY_RUN=1 prints the AWS calls instead of making them.
set -euo pipefail

: "${ENV_NAME:?}" "${BUCKET:?}" "${DISTRIBUTION_ID:?}"
here=$(cd "$(dirname "$0")" && pwd)

if [ "${DRY_RUN:-0}" = 1 ]; then
  aws() {
    echo "+ aws $*" >&2
    case "$1 $2" in
      "s3api list-object-versions") echo "example-previous-version" ;;
    esac
  }
fi

restore() {
  aws s3api copy-object --bucket "$BUCKET" --key index.html \
    --copy-source "$BUCKET/index.html?versionId=$1" --metadata-directive REPLACE \
    --content-type text/html --cache-control "no-cache" >/dev/null
  aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths /index.html >/dev/null
  echo "restored index.html version $1 for $ENV_NAME"
}

if [ "${1:-}" = "--restore" ]; then
  restore "${2:?a version id is required}"
  exit 0
fi

: "${DIST_DIR:?}"

# shellcheck disable=SC2016 # the backticks are JMESPath, not a shell expansion
previous=$(aws s3api list-object-versions --bucket "$BUCKET" --prefix index.html \
  --query 'Versions[?IsLatest==`true`].VersionId' --output text 2>/dev/null || true)
[ "$previous" = "None" ] && previous=""
[ -n "${PUBLISH_STATE:-}" ] && echo "previous_index_version=$previous" >>"$PUBLISH_STATE"

cp "$here/../config/$ENV_NAME.json" "$DIST_DIR/config.json"

# No --delete: tabs still running the previous index.html keep loading its chunks.
aws s3 sync "$DIST_DIR" "s3://$BUCKET" --exclude index.html --exclude config.json \
  --cache-control "public, max-age=31536000, immutable"
aws s3 cp "$DIST_DIR/config.json" "s3://$BUCKET/config.json" --cache-control "no-cache"
aws s3 cp "$DIST_DIR/index.html" "s3://$BUCKET/index.html" --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths /index.html /config.json

echo "published $DIST_DIR to s3://$BUCKET for $ENV_NAME"
