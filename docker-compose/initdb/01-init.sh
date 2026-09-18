#!/bin/sh
# Runs once, when the postgres volume is first created.
# POSTGRES_DB/POSTGRES_USER already created the application database and role;
# Hydra needs a second database owned by that same role.
set -e
: "${HYDRA_DB_NAME:=hydra}"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
  SELECT 'CREATE DATABASE "$HYDRA_DB_NAME"'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$HYDRA_DB_NAME')\gexec
EOSQL
echo "database $HYDRA_DB_NAME created"
