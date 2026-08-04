#!/bin/sh
set -eu

: "${SLACK_WEBHOOK_URL:?Set SLACK_WEBHOOK_URL before enabling Slack notifications}"

context=${KUBE_CONTEXT:-rancher-desktop}
kubectl --context "$context" --namespace monitoring create secret generic slack-webhook-url \
  --from-literal=url="$SLACK_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl --context "$context" apply -f -
kubectl --context "$context" apply -f alerts/slack-alertmanagerconfig.yaml
