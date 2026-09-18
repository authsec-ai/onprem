# Generated from ../.env by deploy.sh -- do not edit; your changes are overwritten.
architecture: ${PG_ARCHITECTURE}
auth:
  username: "${DB_USER}"
  password: "${DB_PASSWORD}"
  database: "${DB_NAME}"
  postgresPassword: "${DB_PASSWORD}"
  replicationPassword: "${DB_PASSWORD}"
global:
  postgresql:
    auth:
      username: "${DB_USER}"
      password: "${DB_PASSWORD}"
      database: "${DB_NAME}"
      postgresPassword: "${DB_PASSWORD}"
      replicationPassword: "${DB_PASSWORD}"
  defaultStorageClass: "${STORAGE_CLASS}"
primary:
  initdb:
    scripts:
      00-create-hydra-db.sql: |
        SELECT 'CREATE DATABASE ${HYDRA_DB_NAME}'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${HYDRA_DB_NAME}')\gexec
