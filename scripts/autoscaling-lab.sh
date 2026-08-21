#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
COLIMA_PROFILE="${COLIMA_PROFILE:-autoscaling-lab}"
DOCKER_SOCKET="${DOCKER_SOCKET:-unix://${HOME}/.colima/${COLIMA_PROFILE}/docker.sock}"
BARO_IMAGE="${BARO_IMAGE:-k8s-monitoring-lab:dev}"
KEDA_VERSION="${KEDA_VERSION:-2.19.0}"
LAB_CLUSTER="${LAB_CLUSTER:-autoscaling-lab-workload}"
MANAGEMENT_CLUSTER="${MANAGEMENT_CLUSTER:-autoscaling-lab-mgmt}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BARO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LAB_BOOTSTRAP="${LAB_BOOTSTRAP:-${BARO_ROOT}/../autoscaling-lab/scripts/create.sh}"

export DOCKER_HOST="${DOCKER_SOCKET}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

preflight() {
  require_command colima
  require_command docker
  require_command kubectl
  require_command openssl
  colima status --profile "${COLIMA_PROFILE}" >/dev/null 2>&1 || die \
    "Colima profile '${COLIMA_PROFILE}' is not running."
  docker info >/dev/null 2>&1 || die "Docker is not reachable through ${DOCKER_SOCKET}."
}

container_by_label() {
  local cluster_name="$1"
  local role="$2"
  local containers count
  containers="$(docker ps --filter "label=io.x-k8s.kind.cluster=${cluster_name}" \
    --filter "label=io.x-k8s.kind.role=${role}" --format '{{.Names}}')"
  count="$(printf '%s\n' "${containers}" | sed '/^$/d' | wc -l | tr -d ' ')"
  test "${count}" = 1 || die "Expected one ${role} container for ${cluster_name}; found ${count}."
  printf '%s\n' "${containers}"
}

LAB_CONTROL_PLANE=""
MANAGEMENT_CONTROL_PLANE=""

connect_clusters() {
  LAB_CONTROL_PLANE="$(container_by_label "${LAB_CLUSTER}" control-plane)"
  MANAGEMENT_CONTROL_PLANE="$(container_by_label "${MANAGEMENT_CLUSTER}" control-plane)"
}

lab_kubectl() {
  docker exec -i "${LAB_CONTROL_PLANE}" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"
}

management_kubectl() {
  docker exec -i "${MANAGEMENT_CONTROL_PLANE}" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"
}

apply_to_lab() {
  local manifest_path="$1"
  lab_kubectl apply -f - < "${manifest_path}"
}

apply_autoscaling_manifests() {
  kubectl kustomize --load-restrictor LoadRestrictionsNone "${BARO_ROOT}/k8s/autoscaling-lab" | lab_kubectl apply -f -
}

patch_consumer_for_node_scaling() {
  lab_kubectl -n kafka-benchmark patch deployment consumer --type strategic \
    --patch "$(cat "${BARO_ROOT}/k8s/autoscaling-lab-consumer-patch.json")"
}

load_image_into_workers() {
  local workers worker
  workers="$(docker ps --filter "label=io.x-k8s.kind.cluster=${LAB_CLUSTER}" \
    --filter 'label=io.x-k8s.kind.role=worker' --format '{{.Names}}')"
  test -n "${workers}" || die "No workload workers are available to preload ${BARO_IMAGE}."
  while IFS= read -r worker; do
    test -n "${worker}" || continue
    docker save "${BARO_IMAGE}" | docker exec -i "${worker}" ctr --namespace k8s.io images import -
  done <<EOF
${workers}
EOF
}

configure_future_worker_preload() {
  test "${BARO_IMAGE}" = k8s-monitoring-lab:dev || die \
    "BARO_IMAGE must match the preloaded lab image k8s-monitoring-lab:dev."
  management_kubectl apply -f - < "${BARO_ROOT}/k8s/autoscaling-lab-worker-template.yaml"
  management_kubectl patch clusterclass quick-start --type json --patch \
    '[{"op":"replace","path":"/spec/workers/machineDeployments/0/infrastructure/templateRef/name","value":"baro-worker-image-template"}]'
}

install_keda() {
  if ! lab_kubectl get namespace keda >/dev/null 2>&1; then
    lab_kubectl apply --server-side -f \
      "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
  fi
  lab_kubectl -n keda rollout status deployment/keda-operator --timeout=5m
  lab_kubectl -n keda rollout status deployment/keda-admission --timeout=5m
  lab_kubectl -n keda rollout status deployment/keda-metrics-apiserver --timeout=5m
}

ensure_local_path_storage() {
  if ! lab_kubectl get storageclass local-path >/dev/null 2>&1; then
    lab_kubectl apply -f \
      https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
  fi
  lab_kubectl label namespace local-path-storage \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite
  apply_to_lab "${BARO_ROOT}/k8s/autoscaling-lab-storage-rbac.yaml"
  lab_kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=5m
}

ensure_postgres_secret() {
  if lab_kubectl -n kafka-benchmark get secret postgres-auth >/dev/null 2>&1; then
    return
  fi
  local password
  password="$(openssl rand -hex 24)"
  lab_kubectl -n kafka-benchmark create secret generic postgres-auth \
    --from-literal=password="${password}" \
    --from-literal=url="postgres://benchmark:${password}@postgres.kafka-benchmark.svc.cluster.local:5432/benchmark?sslmode=disable" \
    --dry-run=client -o yaml | lab_kubectl apply -f -
}

deploy() {
  connect_clusters
  docker build --tag "${BARO_IMAGE}" "${BARO_ROOT}"
  ensure_local_path_storage
  configure_future_worker_preload
  load_image_into_workers
  apply_autoscaling_manifests
  ensure_postgres_secret
  patch_consumer_for_node_scaling
  lab_kubectl -n kafka-benchmark scale deployment/consumer --replicas=1
  lab_kubectl -n kafka-benchmark rollout status statefulset/kafka --timeout=5m
  lab_kubectl -n kafka-benchmark rollout status statefulset/postgres --timeout=5m
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/kafka-topic --timeout=5m
  lab_kubectl -n kafka-benchmark rollout status deployment/ingest --timeout=3m
  lab_kubectl -n kafka-benchmark rollout status deployment/consumer --timeout=3m
  install_keda
  apply_to_lab "${BARO_ROOT}/k8s/keda-consumer.yaml"
  lab_kubectl -n kafka-benchmark get scaledobject benchmark-consumer-lag
  printf '%s\n' 'Baro Kafka consumer is now KEDA-scaled; consumer CPU pressure can trigger CAPI node scale-up.'
}

status() {
  connect_clusters
  lab_kubectl -n kafka-benchmark get deployment,scaledobject,hpa,pod
  management_kubectl get machinedeployment,machine -A
}

ensure_multinode() {
  local machine_deployment
  connect_clusters
  management_kubectl patch cluster "${LAB_CLUSTER}" --type json --patch \
    '[{"op":"replace","path":"/spec/topology/workers/machineDeployments/0/metadata/annotations/cluster.x-k8s.io~1cluster-api-autoscaler-node-group-min-size","value":"2"}]'
  machine_deployment="$(management_kubectl get machinedeployment \
    -l "cluster.x-k8s.io/cluster-name=${LAB_CLUSTER},topology.cluster.x-k8s.io/deployment-name=md-0" \
    -o jsonpath='{.items[0].metadata.name}')"
  test -n "${machine_deployment}" || die "Could not find the CAPI worker MachineDeployment."
  management_kubectl scale machinedeployment "${machine_deployment}" --replicas=2
  management_kubectl wait --for=jsonpath='{.status.readyReplicas}'=2 \
    "machinedeployment/${machine_deployment}" --timeout=10m
  lab_kubectl get nodes
}

bootstrap() {
  test -x "${LAB_BOOTSTRAP}" || die \
    "CAPI bootstrap script is unavailable: ${LAB_BOOTSTRAP}. Set LAB_BOOTSTRAP to a compatible create.sh."
  "${LAB_BOOTSTRAP}"
}

run_benchmark() {
  connect_clusters
  lab_kubectl -n kafka-benchmark delete job benchmark-reset kafka-benchmark-load --ignore-not-found
  lab_kubectl apply -f - < "${BARO_ROOT}/k8s/benchmark-reset-job.yaml"
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/benchmark-reset --timeout=2m
  lab_kubectl apply -f - < "${BARO_ROOT}/load/k6-benchmark-job.yaml"
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/kafka-benchmark-load --timeout=11m
}

down() {
  connect_clusters
  if lab_kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
    lab_kubectl delete -f - < "${BARO_ROOT}/k8s/keda-consumer.yaml" --ignore-not-found
  fi
  lab_kubectl delete namespace kafka-benchmark --ignore-not-found
}

preflight
case "${ACTION}" in
  bootstrap) bootstrap ;;
  deploy) deploy ;;
  status) status ;;
  ensure-multinode) ensure_multinode ;;
  run-benchmark) run_benchmark ;;
  down) down ;;
  *) die "Usage: $0 {bootstrap|deploy|status|ensure-multinode|run-benchmark|down}" ;;
esac
