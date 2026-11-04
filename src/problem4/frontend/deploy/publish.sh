#!/usr/bin/env bash
# Publishes a built SPA (DIST_DIR) to S3 behind CloudFront: hashed assets first
# with a one-year immutable cache, then the environment's config.json and
# index.html with no-cache, then invalidates those two paths and waits for the
# invalidation. Before uploading it records the live versions of both entry
# points, written as previous_index_version=<id> and previous_config_version=<id>
# to the file named by PUBLISH_STATE when set.
# `publish.sh --restore <index-version> [<config-version>]` puts those versions
# back and invalidates them, which is the rollback after a failed smoke test.
# DRY_RUN=1 prints the AWS calls instead of making them.
set -euo pipefail

: "${ENV_NAME:?}" "${BUCKET:?}" "${DISTRIBUTION_ID:?}"
here=$(cd "$(dirname "$0")" && pwd)

if [ "${DRY_RUN:-0}" = 1 ]; then
  aws() {
    echo "+ aws $*" >&2
    case "$1 $2" in
      "s3api list-object-versions") echo "example-previous-version" ;;
      "cloudfront create-invalidation") echo "EXAMPLEINVALIDATION" ;;
    esac
  }
fi

live_version() {
  # shellcheck disable=SC2016 # the backticks are JMESPath, not a shell expansion
  local v
  v=$(aws s3api list-object-versions --bucket "$BUCKET" --prefix "$1" \
    --query "Versions[?Key=='$1' && IsLatest==\`true\`].VersionId" --output text 2>/dev/null || true)
  [ "$v" = "None" ] && v=""
  echo "$v"
}

invalidate() {
  local id
  id=$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "$@" \
    --query Invalidation.Id --output text)
  aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$id"
}

restore_object() {
  aws s3api copy-object --bucket "$BUCKET" --key "$1" \
    --copy-source "$BUCKET/$1?versionId=$2" --metadata-directive REPLACE \
    --content-type "$3" --cache-control "no-cache" >/dev/null
}

if [ "${1:-}" = "--restore" ]; then
  index_version="${2:?an index.html version id is required}"
  config_version="${3:-}"
  restore_object index.html "$index_version" text/html
  paths=(/index.html)
  if [ -n "$config_version" ]; then
    restore_object config.json "$config_version" application/json
    paths+=(/config.json)
  fi
  invalidate "${paths[@]}"
  echo "restored index.html ${index_version}${config_version:+ and config.json $config_version} for $ENV_NAME"
  exit 0
fi

: "${DIST_DIR:?}"

previous_index=$(live_version index.html)
previous_config=$(live_version config.json)
if [ -n "${PUBLISH_STATE:-}" ]; then
  echo "previous_index_version=$previous_index" >>"$PUBLISH_STATE"
  echo "previous_config_version=$previous_config" >>"$PUBLISH_STATE"
fi

cp "$here/../config/$ENV_NAME.json" "$DIST_DIR/config.json"

# No --delete: tabs still running the previous index.html keep loading its chunks.
aws s3 sync "$DIST_DIR" "s3://$BUCKET" --exclude index.html --exclude config.json \
  --cache-control "public, max-age=31536000, immutable"
aws s3 cp "$DIST_DIR/config.json" "s3://$BUCKET/config.json" --cache-control "no-cache"
aws s3 cp "$DIST_DIR/index.html" "s3://$BUCKET/index.html" --cache-control "no-cache"
invalidate /index.html /config.json

echo "published $DIST_DIR to s3://$BUCKET for $ENV_NAME"
