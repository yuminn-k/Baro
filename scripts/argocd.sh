#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
APP_NAME="${2:-}"
CONTEXT="${CONTEXT:-rancher-desktop}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.2.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BARO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

kubectl_cmd() {
  kubectl --context "${CONTEXT}" "$@"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

preflight() {
  require_command kubectl
  kubectl_cmd config current-context >/dev/null
  test "$(kubectl_cmd config current-context)" = "${CONTEXT}" || die \
    "Current context must be '${CONTEXT}'."
}

assert_image_tag_ready() {
  ! grep -q '^    newTag: sha-bootstrap$' \
    "${BARO_ROOT}/gitops/baro-demo/kustomization.yaml" \
    "${BARO_ROOT}/gitops/kafka-benchmark/kustomization.yaml" || die \
    'GitOps image tag is still sha-bootstrap; merge the GHCR image update PR first.'
}

ensure_namespaces() {
  kubectl_cmd apply -f "${BARO_ROOT}/gitops/argocd/bootstrap/namespaces.yaml"
}

wait_for_application() {
  local name="$1"
  kubectl_cmd -n argocd wait \
    --for=jsonpath='{.status.sync.status}'=Synced \
    "application/${name}" --timeout=15m
  kubectl_cmd -n argocd wait \
    --for=jsonpath='{.status.health.status}'=Healthy \
    "application/${name}" --timeout=15m
}

install_argocd() {
  kubectl_cmd create namespace argocd --dry-run=client -o yaml | kubectl_cmd apply -f -
  kubectl_cmd -n argocd apply --server-side --force-conflicts -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
  kubectl_cmd -n argocd wait --for=condition=available \
    deployment/argocd-server deployment/argocd-repo-server \
    deployment/argocd-applicationset-controller --timeout=10m
}

bootstrap() {
  preflight
  assert_image_tag_ready
  install_argocd
  ensure_namespaces
  benchmark_secret
  kubectl_cmd -n argocd apply -f "${BARO_ROOT}/gitops/argocd/projects"
  kubectl_cmd -n argocd apply -f \
    "${BARO_ROOT}/gitops/argocd/applications/platform-monitoring.yaml"
  wait_for_application platform-monitoring
  kubectl_cmd -n argocd apply -f \
    "${BARO_ROOT}/gitops/argocd/applications/baro-demo.yaml"
  kubectl_cmd -n argocd apply -f \
    "${BARO_ROOT}/gitops/argocd/applications/kafka-benchmark.yaml"
  wait_for_application baro-demo
  wait_for_application kafka-benchmark
}

benchmark_secret() {
  preflight
  require_command openssl
  ensure_namespaces
  if kubectl_cmd -n kafka-benchmark get secret postgres-auth >/dev/null 2>&1; then
    return
  fi
  local password
  password="$(openssl rand -hex 24)"
  kubectl_cmd -n kafka-benchmark create secret generic postgres-auth \
    --from-literal=password="${password}" \
    --from-literal=url="postgres://benchmark:${password}@postgres.kafka-benchmark.svc.cluster.local:5432/benchmark?sslmode=disable" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -
}

status() {
  preflight
  kubectl_cmd -n argocd get applications
}

sync_application() {
  preflight
  require_command argocd
  test -n "${APP_NAME}" || die "Usage: scripts/argocd.sh sync <application>"
  argocd app sync "${APP_NAME}"
  argocd app wait "${APP_NAME}" --sync --health
}

suspend() {
  preflight
  for name in platform-monitoring baro-demo kafka-benchmark; do
    kubectl_cmd -n argocd patch "application/${name}" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
  done
}

case "${ACTION}" in
  preflight)
    preflight
    ;;
  bootstrap)
    bootstrap
    ;;
  benchmark-secret)
    benchmark_secret
    ;;
  status)
    status
    ;;
  sync)
    sync_application
    ;;
  suspend)
    suspend
    ;;
  *)
    die "Usage: scripts/argocd.sh {preflight|bootstrap|benchmark-secret|status|sync|suspend} [application]"
    ;;
esac
