# Problem 3: Debugging issues within system

Every `/api/*` call through nginx failed because nginx proxied to the wrong port. Behind it, a Postgres restart crashed the API, a Redis outage failed every request, nginx kept a stale API address, and a database error leaked pool connections. Five weaker points sat beside them: no query timeout, health endpoints hidden from the load balancer, a superuser database login, a Postgres health check that passed too early, and no resource limits. [`tests/smoke.sh`](tests/smoke.sh) runs each failure scenario in CI.

## Contents

- [Scope](#scope)
- [Decisions](#decisions)
- [How I diagnosed it](#how-i-diagnosed-it)
- [Root causes and fixes](#root-causes-and-fixes)
- [Running and verifying](#running-and-verifying)
- [Monitoring and alerts](#monitoring-and-alerts)
- [Preventing this in production](#preventing-this-in-production)

## Scope

### In scope

- **nginx**: the only published port, `127.0.0.1:8080`, proxying to the API.
- **API**: Node 26 and Express; `GET /api/users` reads the database time and records the call in Redis, `GET /status` reports liveness, `GET /ready` reports database reachability.
- **PostgreSQL 15**: the API's only required dependency.
- **Redis 7**: stores `last_call`; the API answers without it.

### Out of scope

- **Application features**: no users table; the handler returns the database time.
- **Production hosting**: replicas, orchestration, backups, host firewall.
- **TLS**: nginx listens on plain HTTP; a terminating proxy sits in front in production.

### Assumptions

- **One Docker host**, so a loopback bind suffices.
- **Tens of concurrent clients**: a pool of 10 per replica against the default `max_connections` of 100.
- **A fresh `pgdata` volume on first start**: the role init script runs only then.
- **Secrets come from the environment**: `.env` locally, masked variables in CI, a secrets manager in production.

## Decisions

| # | Decision | Alternatives considered | Why | Revisit when |
|---|---|---|---|---|
| 1 | nginx re-resolves the upstream (`resolver` plus a variable in `proxy_pass`) | Restart nginx after each API deploy | nginx caches the address at startup; re-resolving needs no operator step | The API gets a stable address |
| 2 | `pool.query()` instead of `connect()` and `release()` by hand | `try/finally` around `release()` | The pool releases or discards the client on every path | A handler needs a transaction |
| 3 | Best-effort Redis write, not awaited | Await behind a short timeout | Redis stores only `last_call`; awaiting put its availability on the request path | The cache serves real data |
| 4 | `service_healthy` for Postgres, `service_started` for Redis | `service_healthy` for both | The API runs without Redis, so Redis health must not block startup | Redis becomes required |
| 5 | Delete the unmounted `init.sql` and `nginx.conf` | Mount them | `max_connections = 20` leaves no headroom; the empty `nginx.conf` stops nginx | Postgres needs tuning |
| 6 | Secrets from the environment and a least-privilege `app` role | Hardcoded superuser | A credential in source is in every clone; a superuser can drop the database | A secrets manager issues short-lived credentials |
| 7 | Query timeouts of 5 s, below nginx's 10 s read timeout | The proxy timeout alone | A stuck query frees its connection at 5 s instead of holding it after nginx answers 504 | A query needs more than 5 s |
| 8 | nginx `1.30` and Node `26`; Postgres stays on `15` | Postgres 17 or 18 | A Postgres major upgrade means `pg_upgrade` or dump and restore, not a stability fix | A maintenance window; PG 15 end of life, November 2027 |
| 9 | Memory limits per service and a loopback bind | No limits; `0.0.0.0:8080` | A leaking process restarts at its limit; the port is reachable from the host only | A load balancer on another host |

## How I diagnosed it

I ran the original stack and worked from the outside in: the request path first, then each dependency failing in turn.

| Step | Command | Observed |
|---|---|---|
| 1 | `curl localhost:8080/api/users`; `wget -qO- localhost:3000/api/users` inside the API container | `502` from nginx (`upstream: "http://172.30.0.4:3001/api/users"`); `{"ok":true,...}` from the API, so the fault is in routing |
| 2 | `docker compose restart postgres` | The API exits with code 1: `Unhandled 'error' event`; no restart policy, so it stays down |
| 3 | `docker compose stop redis`, then call the API | `500` after 20 s of ioredis retries |
| 4 | Port fixed, API recreated on a new IP | `502`; nginx still connects to the old address |
| 5 | `SHOW max_connections`; `wc -c /etc/nginx/nginx.conf`; `\du`; `docker inspect` | `100` and the image default: `init.sql` and `nginx.conf` are mounted nowhere; the API's user is the superuser; `Memory: 0`; nginx on `0.0.0.0:8080` |
| 6 | Reading `api/src/index.js` and `default.conf` | `pool.connect()` with no `finally { release() }`; no `statement_timeout` or `query_timeout`; only `/api/` is proxied, so `/status` gets 404 |
| 7 | `pg_isready` with and without `-h 127.0.0.1` on an empty volume, with a 6 s init script | The socket probe passes at 1 s; the TCP probe at 7 s, when the final server logs `listening on IPv4` |

## Root causes and fixes

| # | Root cause | Impact | Fix |
|---|---|---|---|
| 1 | nginx proxies to `api:3001`; the API listens on `3000` | Every API call returns 502 | [`nginx/conf.d/default.conf`](nginx/conf.d/default.conf) targets port 3000 |
| 2 | nginx resolves `api` once at startup | After the API container is recreated, nginx sends traffic to the released address until restarted | Docker's DNS as `resolver` (`valid=10s`) and the upstream in a variable; 2 s connect and 10 s read timeouts; `X-Request-ID`; upstream timing in the access log |
| 3 | No `error` listener on the `pg` pool | A dropped idle connection crashes the process; no restart policy, so it stays down | `pool.on("error")` in [`api/src/index.js`](api/src/index.js), `restart: unless-stopped`, `init: true` so `SIGTERM` reaches Node |
| 4 | `release()` skipped when the query throws; no acquire timeout | Each failed query keeps a connection; after 10, requests hang and nginx answers 504 | `pool.query()` releases the client on every path; `connectionTimeoutMillis: 2000`; pool size from `DB_POOL_MAX` |
| 5 | The Redis write is awaited with ioredis defaults | Redis stores only `last_call`, yet an outage fails every request after 20 s | Best-effort write, logged on failure; `enableOfflineQueue: false`, `maxRetriesPerRequest: 1`, `commandTimeout: 500` |
| 6 | `depends_on` without health checks | The API and nginx can start before their dependencies accept connections | Postgres (`pg_isready` over TCP) and the API (`/ready`) gate with `service_healthy`; Redis with `service_started` |
| 7 | `postgres/init.sql` (`max_connections = 20`) and an empty `nginx/nginx.conf` are never mounted | Config that looks active but isn't; the empty `nginx.conf` would stop nginx | Both removed; Postgres keeps its default 100 connections |
| 8 | Database password hardcoded in `index.js` and Compose | A credential in source, changed only by a code change | Settings come from [`.env.example`](.env.example) through Compose; `.env` is gitignored; Compose refuses to start without `POSTGRES_PASSWORD` and `APP_DB_PASSWORD` |
| 9 | `node:20` base image (end of life 2026-04-30), `npm install` with no lockfile, root user | No security fixes, unreproducible builds, a root process | `node:26-alpine`, `npm ci --omit=dev`, npm removed (its bundled packages carried HIGH CVEs), a non-root UID, `.dockerignore` |
| 10 | No `statement_timeout` or `query_timeout` on the pool | A stuck query holds its connection after nginx has answered 504; enough of them exhaust the pool | `statement_timeout: 5000` and `query_timeout: 5000`: a 503 at 5 s, and the connection returns to the pool |
| 11 | `/status` and `/ready` are not routed through nginx | The load balancer cannot probe the API | `location = /status` and `location = /ready` proxied to the API |
| 12 | The API connects as the Postgres superuser | A leaked credential or an injected statement can drop databases or create roles | [`postgres/init/01-app-role.sh`](postgres/init/01-app-role.sh) creates `app` with `LOGIN`, `CONNECT` on the database and `USAGE` on `public`; identifiers and the password pass as `psql` variables (`:"user"`, `:'pw'`), never interpolated; the API connects as `APP_DB_USER` |
| 13 | `pg_isready` over the unix socket passes during first-boot init | The temporary init server listens on the socket only, so Postgres reports healthy before its scripts run; the API starts into refused connections | `pg_isready -h 127.0.0.1`, which passes only once the final server accepts TCP |
| 14 | No resource limits; port 8080 on all interfaces | One runaway process can starve the host; the API is reachable from every network | `deploy.resources.limits.memory` (api 256M, nginx 64M, redis 128M, postgres 512M); `127.0.0.1:8080:80` |

## Running and verifying

```bash
cp .env.example .env    # set POSTGRES_PASSWORD and APP_DB_PASSWORD, e.g. openssl rand -base64 20
docker compose up --build --wait
./tests/smoke.sh
```

The role init script runs only on an empty `pgdata` volume; after changing `APP_DB_USER` or `APP_DB_PASSWORD`, run `docker compose down -v` first.

| Check | What it proves | Fault |
|---|---|---|
| `/` and `/api/users` return 200 through nginx | nginx reaches the API on the right port | 1 |
| `/status` and `/ready` return 200 through nginx | Both health endpoints are routed | 11 |
| 500 requests at concurrency 50 all return 200 | A pool of 10 queues 50 clients without errors: capacity, not the leak | 4 (sizing) |
| [`tests/pool-leak.js`](tests/pool-leak.js), run inside the API image against the stack's Postgres | `connect()` plus a throwing query and no `release()` exhausts a pool of 2 after two failures, and `SELECT 1` times out; `pool.query()` on the same query leaves the pool usable after ten | 4 (leak) |
| `/api/users` returns 200 within 5 s while Redis is stopped | Redis stays off the request path | 5 |
| After a Postgres restart the API answers again; its restart count is unchanged | The process survives a dropped connection | 3 (crash) |
| `docker compose stop -t 10 api` exits 0 within the grace period; the API serves again after `start` | `SIGTERM` reaches Node and the shutdown drains | 3 (shutdown) |
| After the API is recreated on a new IP, nginx routes to it without a reload | The upstream is re-resolved | 2 |

The suite fails against the original stack: the first check gets 502. The other faults are configuration: `docker compose config --quiet`, `nginx -t`, hadolint and Trivy run in CI, and `SELECT rolsuper FROM pg_roles WHERE rolname = 'app'` returns `f`. [`api/test/app.test.js`](api/test/app.test.js) covers the handler's failure paths.

## Monitoring and alerts

| Signal | Source | Alert when | Points to |
|---|---|---|---|
| nginx 5xx ratio by `ustatus` | Access log in the `upstream_timing` format | Above 1% for 5 minutes | API unreachable (502); database down or query timeout (503); blocked API (504) |
| p99 `rt` and `urt` | Access log | Above 500 ms for 10 minutes | Pool waiting, slow queries, Redis timeouts |
| Container restarts, health, memory against limit | Docker events, cAdvisor | Any restart in 15 minutes; unhealthy for 1 minute; memory above 85% or an OOM kill | A crash loop, or a leak heading for the limit |
| `/ready` through nginx | Blackbox probe on `:8080/ready` | Failing for 1 minute | The API cannot reach Postgres, or nginx cannot reach the API |
| `canceling statement due to statement timeout` | Postgres log | More than 5 in 5 minutes | A slow query or lock contention |
| Postgres connections and pool `waitingCount` | `postgres_exporter`, API metric | Above 80% of `max_connections`; waiting above 0 for 2 minutes | A leak, or pool size times replicas set too high |
| Redis up, and `cache write failed` log lines | `redis_exporter`, log query | Down for 1 minute | Degraded caching; requests still succeed |

## Preventing this in production

- **Gate every change**: the smoke and fault suite, `docker compose config` and `nginx -t` in CI; every config file in the repo is mounted, or deleted.
- **Review rules for resilience**: release a pooled connection in `finally` or never take it by hand; every emitter has an `error` listener; non-critical dependencies stay off the request path.
- **Bound every wait**: query timeouts below the proxy timeout, a connect timeout on the pool, a memory limit on each container.
- **Size capacity on paper**: pool size times replicas stays below `max_connections` minus the reserved slots.
- **Least privilege and short-lived secrets**: the application role holds `CONNECT` and `USAGE`; in production its password is a short-lived credential from a secrets manager (Vault's database secrets engine, or a rotated Secrets Manager entry).
- **Keep the supply chain current**: a supported base image, lockfile installs, and the Trivy image scan in CI that blocks fixable HIGH and CRITICAL vulnerabilities.
