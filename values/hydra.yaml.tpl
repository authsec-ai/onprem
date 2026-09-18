# Generated from ../.env by deploy.sh -- do not edit; your changes are overwritten.
global:
  hosts:
    oauth: ${OAUTH_HOST}
    oauthAdmin: "${OAUTH_ADMIN_HOST}"
  clusterIssuer: ${CLUSTER_ISSUER}
  ingressClassName: ${INGRESS_CLASS}

secrets:
  dsn: ${HYDRA_DSN_B64}
  dsnPlain: "${HYDRA_DSN}"
  secretsSystem: ${HYDRA_SECRETS_SYSTEM_B64}
  secretsCookie: ${HYDRA_SECRETS_COOKIE_B64}
  pairwiseSalt: ${HYDRA_PAIRWISE_SALT_B64}
  pairwiseSaltPlain: "${HYDRA_PAIRWISE_SALT}"

image:
  repository: oryd/hydra
  tag: v2.3.0

hydra:
  urls:
    selfIssuer: https://${OAUTH_HOST}
    selfPublic: https://${OAUTH_HOST}
    consent: https://${API_HOST}/authsec/hmgr/consent
    login: https://${API_HOST}/authsec/hmgr/login
    logout: https://${API_HOST}/authsec/hmgr/logout
    registration: https://${API_HOST}/authsec/hmgr/registration
    error: https://${API_HOST}/authsec/hmgr/error
    postLogoutRedirect: https://${API_HOST}/authsec/hmgr/
  cors:
    enabled: true
    allowedOrigins: "https://${APP_HOST},https://${API_HOST}"
  cookies:
    domain: ${OAUTH_HOST}
