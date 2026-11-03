#!/usr/bin/env bash
# Runs from /docker-entrypoint-initdb.d on the first boot of an empty data volume.
# Creates the role the API connects as: login only, no superuser, no create rights.
set -Eeo pipefail

: "${APP_DB_USER:?APP_DB_USER is required}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v user="$APP_DB_USER" -v pw="$APP_DB_PASSWORD" -v db="$POSTGRES_DB" <<'EOSQL'
CREATE ROLE :"user" LOGIN PASSWORD :'pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"user";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"user";
EOSQL
