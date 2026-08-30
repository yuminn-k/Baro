#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-}"
test -n "${IMAGE_TAG}" || {
  printf 'Usage: scripts/update-gitops-image.sh sha-<commit>\n' >&2
  exit 1
}
case "${IMAGE_TAG}" in
  sha-*) ;;
  *)
    printf 'Image tag must start with sha-.\n' >&2
    exit 1
    ;;
esac

files=(gitops/baro-demo/kustomization.yaml gitops/kafka-benchmark/kustomization.yaml)
for file in "${files[@]}"; do
  test "$(grep -Ec '^    newTag: sha-' "${file}")" -eq 1 || {
    printf 'Expected one SHA image tag in %s.\n' "${file}" >&2
    exit 1
  }
  sed -i.bak -E "s/^    newTag: sha-.*/    newTag: ${IMAGE_TAG}/" "${file}"
  rm "${file}.bak"
done
