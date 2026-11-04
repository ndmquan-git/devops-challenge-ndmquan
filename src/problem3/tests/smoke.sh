#!/usr/bin/env bash
# Smoke and fault tests for the Compose stack. Run from src/problem3 with the stack up.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL$1" || true; }

wait_for_200() {
  local path=$1 deadline=$((SECONDS + $2))
  until [ "$(status "$path")" = 200 ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

api_container() { docker compose ps -q api; }
api_restarts() { docker inspect -f '{{.RestartCount}}' "$(api_container)"; }
api_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(api_container)"; }

[ "$(status /)" = 200 ] || fail "/ did not return 200"
pass "/ returns 200"

wait_for_200 /api/users 30 || fail "/api/users did not return 200"
pass "/api/users returns 200 through nginx"

[ "$(status /status)" = 200 ] || fail "/status did not return 200 through nginx"
pass "/status returns 200 through nginx"

[ "$(status /ready)" = 200 ] || fail "/ready did not return 200 through nginx"
pass "/ready returns 200 through nginx"

bindings=$(docker inspect -f '{{range .HostConfig.PortBindings}}{{range .}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$(docker compose ps -q nginx)")
[ "${bindings% }" = 127.0.0.1:8080 ] || fail "nginx is published on ${bindings% }, not only on 127.0.0.1:8080"
pass "nginx is published on 127.0.0.1:8080 only"

limits=""
for service in $(docker compose config --services); do
  bytes=$(docker inspect -f '{{.HostConfig.Memory}}' "$(docker compose ps -q "$service")")
  [ "$bytes" -gt 0 ] || fail "$service has no memory limit"
  limits+=" $service=$((bytes / 1048576))M"
done
pass "every service has a memory limit:$limits"

role=$(docker compose exec -T api node -e '
  const { Client } = require("pg");
  const { DB_HOST: host, DB_USER: user, DB_PASSWORD: password, DB_NAME: database } = process.env;
  const client = new Client({ host, user, password, database });
  client.connect()
    .then(() => client.query("SELECT current_user AS name, rolsuper FROM pg_roles WHERE rolname = current_user"))
    .then(({ rows }) => console.log(rows[0].name, rows[0].rolsuper))
    .finally(() => client.end());') || fail "could not read the api's database role"
[ "${role#* }" = false ] || fail "the api logs in as a superuser ($role)"
pass "the api logs in as ${role% *}, which is not a superuser"

if POSTGRES_PASSWORD='' APP_DB_PASSWORD='' docker compose config --quiet 2>/dev/null; then
  fail "compose accepted empty database passwords"
fi
pass "compose refuses to start without POSTGRES_PASSWORD and APP_DB_PASSWORD"

ok=$(seq 500 | xargs -P 50 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "$BASE_URL/api/users" | grep -c '^200$' || true)
[ "$ok" = 500 ] || fail "only $ok of 500 concurrent requests returned 200"
pass "500 requests at concurrency 50 all return 200"

docker compose --progress quiet run --rm --no-deps -T -v "$PWD/tests/pool-leak.js:/app/pool-leak.js:ro" api node /app/pool-leak.js \
  || fail "pool-leak proof did not hold"
pass "pool-leak proof: connect() without release() exhausts the pool, pool.query() does not"

docker compose stop redis >/dev/null 2>&1
code=$(status /api/users)
docker compose start redis >/dev/null 2>&1
[ "$code" = 200 ] || fail "with redis stopped, /api/users returned $code"
pass "/api/users returns 200 within 5s while redis is down"

# Leave an idle pooled connection, so the frozen server meets the query timeout, not the connect timeout.
status /api/users >/dev/null
docker compose pause postgres >/dev/null 2>&1
frozen=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 "$BASE_URL/api/users" || true)
docker compose unpause postgres >/dev/null 2>&1
code=${frozen% *} seconds=${frozen#* }
[ "$code" = 503 ] || fail "with postgres frozen, /api/users returned $code after ${seconds}s"
awk -v s="$seconds" 'BEGIN { exit !(s >= 4.5 && s < 10) }' \
  || fail "with postgres frozen, /api/users answered after ${seconds}s, not at the 5s query timeout"
wait_for_200 /api/users 30 || fail "/api/users did not recover after postgres was unfrozen"
pass "with postgres frozen, /api/users returns 503 after ${seconds}s, inside nginx's 10s read timeout"

restarts=$(api_restarts)
docker compose restart postgres >/dev/null 2>&1
wait_for_200 /api/users 30 || fail "/api/users did not recover after a postgres restart"
[ "$(api_restarts)" = "$restarts" ] || fail "the api process crashed when postgres restarted"
pass "api survives a postgres restart and recovers"

cid=$(api_container)
started=$SECONDS
docker compose stop -t 10 api >/dev/null 2>&1
elapsed=$((SECONDS - started))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
docker compose start api >/dev/null 2>&1
[ "$exit_code" = 0 ] || fail "api exited with code $exit_code on SIGTERM after ${elapsed}s"
[ "$elapsed" -le 10 ] || fail "api took ${elapsed}s to stop, longer than the 10s grace period"
wait_for_200 /api/users 30 || fail "/api/users did not return 200 after the api was started again"
pass "api exits 0 on SIGTERM within the grace period (${elapsed}s) and serves again after start"

old_ip=$(api_ip)
network=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$(api_container)")
docker compose rm -sf api >/dev/null 2>&1
# Occupy the freed address so the recreated api must come back on a new IP.
holder=$(docker run -d --rm --network "$network" alpine:3 sleep 300)
trap 'docker rm -f "$holder" >/dev/null 2>&1' EXIT
docker compose up -d --no-deps api >/dev/null 2>&1
[ "$(api_ip)" != "$old_ip" ] || fail "test setup: the recreated api kept $old_ip"
wait_for_200 /api/users 40 || fail "nginx did not route to the recreated api ($old_ip -> $(api_ip))"
pass "nginx routes to the recreated api without a reload ($old_ip -> $(api_ip))"
