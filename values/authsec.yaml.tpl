# Generated from ../.env by deploy.sh -- do not edit; your changes are overwritten.
global:
  hosts:
    app: ${APP_HOST}
    api: ${API_HOST}
  clusterIssuer: ${CLUSTER_ISSUER}
  ingressClassName: ${INGRESS_CLASS}
  imagePullSecret: "${IMAGE_PULL_SECRET}"

postgresDb:
  dbHost: "${DB_HOST}"
  dbPort: "${DB_PORT}"
  dbUser: "${DB_USER}"
  dbPassword: "${DB_PASSWORD}"
  dbName: "${DB_NAME}"
  dbSchema: "public"

smtp:
  smtpHost: "${SMTP_HOST}"
  smtpPort: "${SMTP_PORT}"
  smtpUser: "${SMTP_USER}"
  smtpPassword: "${SMTP_PASSWORD}"

encryption:
  key: "${ENCRYPTION_KEY}"

authsec:
  image:
    repository: ${REGISTRY}/authsec
    tag: ${IMAGE_TAG}
  env:
    jwtSecret: "${JWT_SECRET}"
    jwtDefSecret: "${JWT_DEF_SECRET}"
    jwtSdkSecret: "${JWT_SDK_SECRET}"
    sessionSecret: "${SESSION_SECRET}"
    authsecOidcStateHmacKey: "${OIDC_STATE_HMAC_KEY}"
    totpEncryptionKey: "${TOTP_ENCRYPTION_KEY}"
    syncConfigEncryptionKey: "${SYNC_CONFIG_ENCRYPTION_KEY}"
    webauthnRpName: "${DOMAIN}"
    webauthnRpId: "${APP_HOST}"
    webauthnOrigin: "https://${APP_HOST}"
    hydraAdminUrl: "http://hydra-admin.${NS_HYDRA}.svc.cluster.local:4445"
    hydraPublicUrl: "https://${OAUTH_HOST}"
    hydraServiceUrl: "http://hydra-public.${NS_HYDRA}.svc.cluster.local:4444"
    baseUrl: "https://${APP_HOST}"
    publicUiOrigin: "https://${APP_HOST}"
    tenantDomainSuffix: "${APP_HOST}"
    corsAllowedOrigin: "https://${APP_HOST}"
    corsAllowOrigin: "https://${APP_HOST}"
    oauthAuthUrl: "https://${OAUTH_HOST}/oauth2/auth"
    oauthTokenUrl: "https://${OAUTH_HOST}/oauth2/token"
    oauthUserInfoUrl: "https://${OAUTH_HOST}/userinfo"
    vaultAddr: "http://${REL_VAULT}.${NS_VAULT}.svc.cluster.local:8200"

ui:
  image:
    repository: ${REGISTRY}/ui
    tag: ${IMAGE_TAG}

logaggregator:
  image:
    repository: ${REGISTRY}/log-aggregator
    tag: ${IMAGE_TAG}
  env:
    fluentBitUrl: "http://${REL_FLUENTBIT}.${NS_LOGGING}.svc.cluster.local:2020"

logagent:
  image:
    repository: ${REGISTRY}/log-agent
    tag: ${IMAGE_TAG}

spireheadless:
  image:
    repository: ${REGISTRY}/spire-headless
    tag: ${IMAGE_TAG}
  env:
    vault_addr: "http://${REL_VAULT}.${NS_VAULT}.svc.cluster.local:8200"
    vault_namespace: "${NS_VAULT}"
    jwt_def_secret: "${JWT_DEF_SECRET}"
    jwt_sdk_secret: "${JWT_SDK_SECRET}"

minio:
  rootUser: "${MINIO_ROOT_USER}"
  rootPassword: "${MINIO_ROOT_PASSWORD}"
  environment:
    MINIO_BROWSER_REDIRECT_URL: "https://${APP_HOST}"
