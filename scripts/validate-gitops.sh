#!/bin/sh
set -eu

app_dir='gitops/argocd/applications'
test "$(find "$app_dir" -maxdepth 1 -type f -name '*.yaml' | wc -l | tr -d ' ')" -eq 3
for app in platform-monitoring baro-demo kafka-benchmark; do
  test "$(grep -l "^  name: ${app}$" "$app_dir"/*.yaml | wc -l | tr -d ' ')" -eq 1
done

demo_manifest="$(kubectl kustomize gitops/baro-demo)"
kafka_manifest="$(kubectl kustomize gitops/kafka-benchmark)"
platform_manifest="$(kubectl kustomize gitops/platform-monitoring/resources)"
application_manifests="$(printf '%s\n' "$demo_manifest" "$kafka_manifest")"

printf '%s\n' "$application_manifests" | grep -q 'image: ghcr.io/yuminn-k/baro:sha-'
test "$(printf '%s\n' "$application_manifests" | grep -c 'image: ghcr.io/yuminn-k/baro:sha-')" -eq 4
test "$(printf '%s\n' "$application_manifests" | grep -c 'imagePullPolicy: IfNotPresent')" -eq 4
! printf '%s\n' "$application_manifests" | grep -q 'k8s-monitoring-lab:dev'
! printf '%s\n' "$application_manifests" | grep -q 'imagePullPolicy: Never'
! printf '%s\n' "$application_manifests" | grep -E '^kind: (ScaledObject|HorizontalPodAutoscaler|Machine|MachineDeployment)$'
! printf '%s\n' "$kafka_manifest" | grep -E 'benchmark-reset|kafka-benchmark-load|benchmark-verify'
printf '%s\n' "$kafka_manifest" | grep -q 'argocd.argoproj.io/hook: PostSync'
printf '%s\n' "$platform_manifest" | grep -q 'kind: PrometheusRule'
! grep -R -n -E '^kind: Secret$|^stringData:' gitops
! grep -n -E '(^[[:space:]]*(commit-message|title):|immutable GHCR image built from).*\${GITHUB_SHA}' .github/workflows/main-image-and-gitops.yml
grep -q 'commit-message: "chore: update GitOps image to \${{ github.sha }}"' .github/workflows/main-image-and-gitops.yml
grep -q 'title: "chore: deploy \${{ github.sha }} via GitOps"' .github/workflows/main-image-and-gitops.yml
grep -q 'platforms: linux/amd64,linux/arm64' .github/workflows/main-image-and-gitops.yml
grep -q 'uses: docker/setup-buildx-action@v3' .github/workflows/main-image-and-gitops.yml
grep -q 'IMAGE_NAME: ghcr.io/yuminn-k/baro' .github/workflows/main-image-and-gitops.yml
! grep -R -n 'ghcr.io/yuminn-k/k8s-monitoring' .github gitops
test "$(printf '%s\n' "$application_manifests" | grep -c 'maxSurge: 0')" -eq 4

render_helm() {
  if ! helm repo list | awk 'NR > 1 { print $1 }' | grep -qx prometheus-community; then
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  fi
  helm template monitoring prometheus-community/kube-prometheus-stack \
    --version 88.1.3 \
    --values gitops/platform-monitoring/values.yaml >/dev/null
}

if ! render_helm; then
  if [ "${CI:-false}" = true ]; then
    exit 1
  fi
  printf '%s\n' 'Helm chart render skipped locally because the chart could not be downloaded.' >&2
fi
