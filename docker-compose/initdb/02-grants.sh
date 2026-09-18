#!/bin/sh
# PostgreSQL 15+ removes CREATE on the public schema from ordinary roles, so the
# owner has to be set explicitly or Hydra's migration fails.
set -e
: "${HYDRA_DB_NAME:=hydra}"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$HYDRA_DB_NAME" <<EOSQL
  ALTER DATABASE "$HYDRA_DB_NAME" OWNER TO "$POSTGRES_USER";
  ALTER SCHEMA public OWNER TO "$POSTGRES_USER";
  GRANT ALL ON SCHEMA public TO "$POSTGRES_USER";
EOSQL
echo "$HYDRA_DB_NAME prepared for $POSTGRES_USER"
