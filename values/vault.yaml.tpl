# Generated from ../.env by deploy.sh -- do not edit; your changes are overwritten.
server:
  vaultInit:
    enabled: true
    username: "${VAULT_USERNAME}"
    password: "${VAULT_PASSWORD}"
    syncNamespaces:
      - ${NS_APP}
  dataStorage:
    storageClass: ${STORAGE_CLASS_OR_NULL}
