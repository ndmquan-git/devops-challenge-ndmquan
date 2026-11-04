#!/usr/bin/env bash
# Rolls IMAGE out to the running instances tagged App=$APP_TAG, Env=$ENV_NAME,
# one at a time: drain from the ALB target group, run deploy.sh through SSM,
# re-register, wait until in service. Stops at the first failed instance.
# DRAINED_FILE holds the target currently out of service. DRY_RUN=1 prints the
# AWS calls instead of making them.
set -euo pipefail

: "${IMAGE:?}" "${APP_TAG:?}" "${ENV_NAME:?}" "${TARGET_GROUP_ARN:?}" "${COSIGN_IDENTITY_REGEXP:?}"
PORT="${PORT:-8080}"
DELIVERY_TIMEOUT="${DELIVERY_TIMEOUT:-60}"
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-600}"
DRAINED_FILE="${DRAINED_FILE:-/dev/null}"
here=$(cd "$(dirname "$0")" && pwd)

if [ "${DRY_RUN:-0}" = 1 ]; then
  aws() {
    echo "+ aws $*" >&2
    case "$1 $2" in
      "ec2 describe-instances") printf 'i-0example000000001\ti-0example000000002\n' ;;
      "ssm send-command") echo "00000000-0000-0000-0000-000000000000" ;;
      "ssm get-command-invocation") echo "Success" ;;
    esac
  }
fi

read -r -a instances <<<"$(aws ec2 describe-instances \
  --filters "Name=tag:App,Values=$APP_TAG" "Name=tag:Env,Values=$ENV_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
[ "${#instances[@]}" -gt 0 ] || { echo "no running instances for App=$APP_TAG Env=$ENV_NAME" >&2; exit 1; }

params=$(mktemp)
trap 'rm -f "$params"' EXIT
jq -n --arg script "$(base64 <"$here/deploy.sh" | tr -d '\n')" --arg image "$IMAGE" --arg port "$PORT" \
  --arg cosign "$COSIGN_IDENTITY_REGEXP" --arg timeout "$COMMAND_TIMEOUT" '{
  commands: [
    "echo \($script) | base64 -d > /tmp/p4-deploy.sh",
    "IMAGE=\($image | @sh) PORT=\($port | @sh) COSIGN_IDENTITY_REGEXP=\($cosign | @sh) bash /tmp/p4-deploy.sh"
  ],
  executionTimeout: [$timeout]
}' >"$params"

# --timeout-seconds bounds delivery to the agent and executionTimeout the run, so
# the command ends within both; the CLI waiter gives up after about 100 s.
wait_command() {
  local deadline=$((SECONDS + DELIVERY_TIMEOUT + COMMAND_TIMEOUT + 30)) status
  while :; do
    status=$(aws ssm get-command-invocation --command-id "$1" --instance-id "$2" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) return 0 ;;
      Failed | Cancelled | Cancelling | TimedOut) return 1 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

for id in "${instances[@]}"; do
  target="Id=$id,Port=$PORT"
  echo "==> $id: drain"
  echo "$target" >"$DRAINED_FILE"
  aws elbv2 deregister-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"
  aws elbv2 wait target-deregistered --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"

  echo "==> $id: deploy $IMAGE"
  command_id=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --comment "deploy $APP_TAG $ENV_NAME" --timeout-seconds "$DELIVERY_TIMEOUT" \
    --parameters "file://$params" --query Command.CommandId --output text)
  deployed=1
  wait_command "$command_id" "$id" || deployed=0

  # deploy.sh has already rolled the instance back on failure, so it goes back in either way.
  echo "==> $id: register"
  aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"
  : >"$DRAINED_FILE"
  aws elbv2 wait target-in-service --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"

  if [ "$deployed" = 0 ]; then
    aws ssm get-command-invocation --command-id "$command_id" --instance-id "$id" \
      --query StandardErrorContent --output text >&2
    echo "deploy failed on $id; stopping the rollout" >&2
    exit 1
  fi
done

echo "rolled out $IMAGE to ${#instances[@]} instance(s)"
