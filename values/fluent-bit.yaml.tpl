# Generated from ../.env by deploy.sh -- do not edit; your changes are overwritten.
nameOverride: "${REL_FLUENTBIT}"
ingress:
  enabled: false
metrics:
  enabled: true
  serviceMonitor:
    enabled: ${PROMETHEUS_OPERATOR}
