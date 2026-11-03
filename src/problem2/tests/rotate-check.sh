#!/usr/bin/env bash
# Proves that log rotation makes NGINX reopen its logs, in a disposable
# ubuntu:24.04 container driven from the host with Docker.
#   positive: the packaged /etc/logrotate.d/nginx rotates and every NGINX
#             process ends up on the new inodes, with no "(deleted)" descriptor.
#   negative: a copy of that config without its postrotate block must make the
#             same assertions fail, which shows the check can fail.
# Usage: tests/rotate-check.sh [positive|negative|both]   (default: both)
# Prints one "ok -" or "FAIL:" line per assertion, exits 1 on any failure, and
# always removes the container.
set -euo pipefail

MODE="${1:-both}"
IMAGE="${IMAGE:-ubuntu:24.04}"
REQUESTS="${REQUESTS:-50}"
NAME="p2-rotate-$$-$RANDOM"
FAILURES=0
INNER=()

case $MODE in
  positive | negative | both) ;;
  *) echo "usage: $0 [positive|negative|both]" >&2; exit 2 ;;
esac

ok()         { echo "ok - $*"; }
fail()       { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
inner_ok()   { INNER+=("ok - $*"); }
inner_fail() { INNER+=("FAIL: $*"); }
dx()         { docker exec "$NAME" "$@"; }
cleanup()    { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# One line per NGINX process and open log descriptor: "pid fd inode target".
# A deleted file reads "... /var/log/nginx/access.log (deleted)".
fd_table() {
  # shellcheck disable=SC2016  # the single-quoted script expands inside the container
  dx bash -c '
    for pid in $(pgrep -x nginx); do
      for fd in /proc/$pid/fd/*; do
        target=$(readlink "$fd") || continue
        case $target in
          /var/log/nginx/*) printf "%s %s %s %s\n" "$pid" "${fd##*/}" "$(stat -L -c %i "$fd" 2>/dev/null || echo "?")" "$target" ;;
        esac
      done
    done'
}

# check_rotation <label> <logrotate config>: fills INNER with one result line per
# assertion and returns the number of failed assertions.
check_rotation() {
  local label=$1 conf=$2 failed=0 before after old_access new_access new_error pids pid line
  INNER=()
  dx bash -c "for _ in \$(seq $REQUESTS); do curl -s -o /dev/null http://127.0.0.1/; done"
  old_access=$(dx stat -c %i /var/log/nginx/access.log)
  before=$(fd_table)
  pids=$(dx pgrep -x nginx | sort -n | tr '\n' ' ')
  if [[ $(dx stat -c %s /var/log/nginx/access.log) -gt 0 ]]; then
    inner_ok "$label: access.log has content before rotation"
  else
    inner_fail "$label: access.log is empty before rotation"
  fi
  if [[ -n $before ]]; then
    inner_ok "$label: recorded log descriptors for nginx pids $pids"
  else
    inner_fail "$label: no log descriptors found for nginx pids $pids"
  fi
  dx logrotate -f "$conf" || inner_fail "$label: logrotate -f $conf exited $?"
  sleep 1
  after=$(fd_table)
  new_access=$(dx stat -c %i /var/log/nginx/access.log)
  new_error=$(dx stat -c %i /var/log/nginx/error.log)
  if [[ $new_access != "$old_access" ]]; then
    inner_ok "$label: access.log was rotated (inode $old_access to $new_access)"
  else
    inner_fail "$label: access.log inode unchanged ($old_access), nothing was rotated"
  fi
  if grep -q '(deleted)' <<<"$after"; then
    inner_fail "$label: a descriptor points at a deleted log"
  else
    inner_ok "$label: no descriptor points at a deleted log"
  fi
  for pid in $pids; do
    if grep -qE "^$pid [0-9]+ $new_access /var/log/nginx/access.log$" <<<"$after" \
      && grep -qE "^$pid [0-9]+ $new_error /var/log/nginx/error.log$" <<<"$after" \
      && ! grep -qE "^$pid [0-9]+ [0-9?]+ /var/log/nginx/.*(\.log\.[0-9]|\.gz|\(deleted\))" <<<"$after"; then
      inner_ok "$label: pid $pid writes to the new access.log and error.log"
    else
      inner_fail "$label: pid $pid holds $(grep "^$pid " <<<"$after" | awk '{ print "inode " $3 " " $4 }' | sort -u | paste -sd ';' -)"
    fi
  done
  dx curl -s -o /dev/null http://127.0.0.1/
  if [[ $(dx stat -c %s /var/log/nginx/access.log) -gt 0 ]]; then
    inner_ok "$label: the new access.log grows after a request"
  else
    inner_fail "$label: the new access.log is still empty after a request"
  fi
  for line in "${INNER[@]}"; do
    if [[ $line == FAIL:* ]]; then failed=$((failed + 1)); fi
  done
  return "$failed"
}

echo "# container $NAME from $IMAGE"
# Root in the container must read the www-data workers' /proc/<pid>/fd, which needs CAP_SYS_PTRACE.
docker run -d --name "$NAME" --cap-add SYS_PTRACE "$IMAGE" sleep infinity >/dev/null
# systemd-sysv provides /sbin/init as on the VM: without it, and without a
# policy-rc.d, invoke-rc.d prints "No init system and policy-rc.d missing!
# Defaulting to block." and runs nothing, which the postrotate's redirect hides.
dx bash -c 'export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends nginx logrotate curl procps ca-certificates systemd-sysv >/dev/null'
# The image ships /usr/sbin/policy-rc.d (exit 101), which turns invoke-rc.d into a no-op; a VM has none.
dx rm -f /usr/sbin/policy-rc.d
dx nginx
sleep 1
echo "# $(dx nginx -v 2>&1), $(dx logrotate --version 2>&1 | head -n 1), nginx pids: $(dx pgrep -x nginx | paste -sd ' ' -)"

if [[ $MODE == positive || $MODE == both ]]; then
  n=0
  check_rotation positive /etc/logrotate.d/nginx || n=$?
  printf '%s\n' "${INNER[@]}"
  FAILURES=$((FAILURES + n))
fi

if [[ $MODE == negative || $MODE == both ]]; then
  dx bash -c "sed '/postrotate/,/endscript/d' /etc/logrotate.d/nginx > /root/nginx-no-postrotate.conf && ! grep -q postrotate /root/nginx-no-postrotate.conf"
  n=0
  check_rotation negative /root/nginx-no-postrotate.conf || n=$?
  for line in "${INNER[@]}"; do echo "  negative run: $line"; done
  if (( n > 0 )); then
    ok "negative run: a missing postrotate is detected ($n of ${#INNER[@]} assertions failed)"
  else
    fail "negative run: every assertion passed with the postrotate block removed, so the check cannot detect a broken reopen"
  fi
fi

if (( FAILURES > 0 )); then
  echo "# $FAILURES failed"
  exit 1
fi
echo "# all assertions passed"
