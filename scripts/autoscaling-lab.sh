#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
COLIMA_PROFILE="${COLIMA_PROFILE:-autoscaling-lab}"
DOCKER_SOCKET="${DOCKER_SOCKET:-unix://${HOME}/.colima/${COLIMA_PROFILE}/docker.sock}"
BARO_IMAGE="${BARO_IMAGE:-k8s-monitoring-lab:dev}"
KEDA_VERSION="${KEDA_VERSION:-2.19.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-0.8.1}"
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

topic_partition_count() {
  lab_kubectl -n kafka-benchmark exec statefulset/kafka -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka.kafka-benchmark.svc.cluster.local:9092 \
    --describe --topic benchmark-events | \
    awk '{ for (i = 1; i <= NF; i++) if ($i == "PartitionCount:") { print $(i + 1); exit } }'
}

ensure_topic_partitions() {
  local attempt partitions
  for attempt in $(seq 1 60); do
    partitions="$(topic_partition_count || true)"
    if [[ "${partitions}" =~ ^[0-9]+$ ]] && (( partitions >= 12 )); then
      return
    fi
    sleep 5
  done
  die "Kafka topic benchmark-events did not reach 12 partitions."
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

install_metrics_server() {
  local metric_args attempt
  if ! lab_kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
    lab_kubectl apply -f \
      "https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml"
  fi
  metric_args="$(lab_kubectl -n kube-system get deployment metrics-server \
    -o jsonpath='{.spec.template.spec.containers[0].args[*]}')"
  if ! printf '%s\n' "${metric_args}" | tr ' ' '\n' | grep -Fx -- '--kubelet-insecure-tls' >/dev/null; then
    lab_kubectl -n kube-system patch deployment metrics-server --type json --patch \
      '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  fi
  lab_kubectl -n kube-system rollout status deployment/metrics-server --timeout=5m
  for attempt in $(seq 1 36); do
    if lab_kubectl get --raw=/apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1 && \
      lab_kubectl top nodes >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done
  die "Metrics Server did not expose pod CPU metrics."
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
  ensure_multinode
  docker build --tag "${BARO_IMAGE}" "${BARO_ROOT}"
  ensure_local_path_storage
  install_metrics_server
  configure_future_worker_preload
  load_image_into_workers
  lab_kubectl -n kafka-benchmark delete job kafka-topic --ignore-not-found
  apply_autoscaling_manifests
  ensure_postgres_secret
  patch_consumer_for_node_scaling
  lab_kubectl -n kafka-benchmark scale deployment/consumer --replicas=1
  lab_kubectl -n kafka-benchmark rollout status statefulset/kafka --timeout=5m
  lab_kubectl -n kafka-benchmark rollout status statefulset/postgres --timeout=5m
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/kafka-topic --timeout=5m
  ensure_topic_partitions
  lab_kubectl -n kafka-benchmark rollout status deployment/ingest --timeout=3m
  lab_kubectl -n kafka-benchmark rollout status deployment/consumer --timeout=3m
  install_keda
  apply_to_lab "${BARO_ROOT}/k8s/keda-consumer.yaml"
  lab_kubectl -n kafka-benchmark get scaledobject benchmark-consumer-lag
  printf '%s\n' 'Baro Kafka consumer is now KEDA-scaled; consumer CPU pressure can trigger CAPI node scale-up.'
}

status() {
  connect_clusters
  printf 'benchmark-events partitions: %s\n' "$(topic_partition_count || true)"
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

hpa_desired_replicas() {
  local hpa_name="$1"
  lab_kubectl -n kafka-benchmark get hpa "${hpa_name}" -o jsonpath='{.status.desiredReplicas}'
}

machine_deployment_replicas() {
  management_kubectl get machinedeployment \
    -l "cluster.x-k8s.io/cluster-name=${LAB_CLUSTER},topology.cluster.x-k8s.io/deployment-name=md-0" \
    -o jsonpath='{.items[0].status.replicas}'
}

ready_worker_count() {
  lab_kubectl get nodes -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
    --no-headers | awk '$2 ~ /^Ready/ { count += 1 } END { print count + 0 }'
}

pending_consumer_count() {
  lab_kubectl -n kafka-benchmark get pods -l app.kubernetes.io/name=consumer \
    --field-selector=status.phase=Pending --no-headers 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '
}

record_spike_state() {
  local consumer_replicas ingest_replicas workers ready_workers pending_consumers partitions lag
  consumer_replicas="$(hpa_desired_replicas keda-hpa-benchmark-consumer-lag || true)"
  ingest_replicas="$(hpa_desired_replicas ingest-cpu || true)"
  workers="$(machine_deployment_replicas || true)"
  ready_workers="$(ready_worker_count || true)"
  pending_consumers="$(pending_consumer_count || true)"
  partitions="$(topic_partition_count || true)"
  lag="$(consumer_lag || true)"
  printf 'SPIKE_STATE time=%s partitions=%s consumer_hpa=%s ingest_hpa=%s pending_consumers=%s workers=%s ready_workers=%s consumer_lag=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${partitions:-unknown}" "${consumer_replicas:-unknown}" \
    "${ingest_replicas:-unknown}" "${pending_consumers:-unknown}" "${workers:-unknown}" \
    "${ready_workers:-unknown}" "${lag:-unknown}"
}

wait_for_spike_scale_up() {
  local deadline consumer_replicas ingest_replicas workers pending_consumers
  local consumer_scaled=false ingest_scaled=false workers_scaled=false consumer_pending=false
  deadline=$(( $(date +%s) + 420 ))
  while (( $(date +%s) < deadline )); do
    consumer_replicas="$(hpa_desired_replicas keda-hpa-benchmark-consumer-lag || true)"
    ingest_replicas="$(hpa_desired_replicas ingest-cpu || true)"
    workers="$(machine_deployment_replicas || true)"
    pending_consumers="$(pending_consumer_count || true)"
    record_spike_state
    if [[ "${consumer_replicas:-0}" =~ ^[0-9]+$ ]] && (( consumer_replicas >= 3 )); then
      consumer_scaled=true
    fi
    if [[ "${ingest_replicas:-0}" =~ ^[0-9]+$ ]] && (( ingest_replicas > 2 )); then
      ingest_scaled=true
    fi
    if [[ "${workers:-0}" =~ ^[0-9]+$ ]] && (( workers >= 3 )) && (( $(ready_worker_count) >= 3 )); then
      workers_scaled=true
    fi
    if [[ "${pending_consumers:-0}" =~ ^[0-9]+$ ]] && (( pending_consumers > 0 )); then
      consumer_pending=true
    fi
    if [[ "${consumer_scaled}" = true && "${ingest_scaled}" = true && "${workers_scaled}" = true && "${consumer_pending}" = true ]]; then
      return
    fi
    if [[ "$(lab_kubectl -n kafka-benchmark get job k6-autoscaling-spike -o jsonpath='{.status.failed}' 2>/dev/null || true)" != "" ]]; then
      die "Spike job failed before autoscaling completed."
    fi
    sleep 5
  done
  die "Spike did not prove consumer KEDA scale-up, ingest HPA scale-up, pending consumer, and a third ready worker."
}

consumer_lag() {
  lab_kubectl -n kafka-benchmark exec statefulset/kafka -- \
    /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka.kafka-benchmark.svc.cluster.local:9092 \
    --describe --group benchmark-consumers | awk 'NR > 1 && $6 != "-" { lag += $6 } END { print lag + 0 }'
}

wait_for_zero_consumer_lag() {
  local attempt lag
  for attempt in $(seq 1 360); do
    lag="$(consumer_lag)"
    [[ "${lag}" = 0 ]] && return
    sleep 5
  done
  die "Kafka consumer lag did not return to zero after the spike."
}

wait_for_spike_recovery() {
  local deadline consumer_replicas ingest_replicas workers
  deadline=$(( $(date +%s) + 720 ))
  while (( $(date +%s) < deadline )); do
    consumer_replicas="$(hpa_desired_replicas keda-hpa-benchmark-consumer-lag || true)"
    ingest_replicas="$(hpa_desired_replicas ingest-cpu || true)"
    workers="$(machine_deployment_replicas || true)"
    if [[ "${consumer_replicas:-0}" = 1 && "${ingest_replicas:-0}" = 2 && "${workers:-0}" = 2 ]]; then
      return
    fi
    sleep 10
  done
  die "Autoscalers did not recover to consumer=1, ingest=2, workers=2 after the spike."
}

run_spike() {
  connect_clusters
  ensure_topic_partitions
  lab_kubectl -n kafka-benchmark delete job benchmark-reset k6-autoscaling-spike spike-verify --ignore-not-found
  lab_kubectl apply -f - < "${BARO_ROOT}/k8s/benchmark-reset-job.yaml"
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/benchmark-reset --timeout=2m
  lab_kubectl apply -f - < "${BARO_ROOT}/load/k6-autoscaling-spike-job.yaml"
  wait_for_spike_scale_up
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/k6-autoscaling-spike --timeout=8m
}

verify_spike() {
  connect_clusters
  wait_for_zero_consumer_lag
  lab_kubectl -n kafka-benchmark delete job spike-verify --ignore-not-found
  lab_kubectl apply -f - < "${BARO_ROOT}/k8s/spike-verify-job.yaml"
  lab_kubectl -n kafka-benchmark wait --for=condition=complete job/spike-verify --timeout=2m
  wait_for_spike_recovery
  printf '%s\n' 'Spike completed without duplicate events; Kafka lag is zero and autoscalers recovered.'
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
  run-spike) run_spike ;;
  verify-spike) verify_spike ;;
  *) die "Usage: $0 {bootstrap|deploy|status|ensure-multinode|run-benchmark|run-spike|verify-spike|down}" ;;
esac
