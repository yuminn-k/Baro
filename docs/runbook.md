# 운영 및 검증 가이드

## 일상 명령

| 상황 | 명령 | 성공 기준 |
| --- | --- | --- |
| 클러스터 연결 확인 | `make preflight` | Rancher Desktop 노드가 `Ready` |
| 코드와 필수 설정 확인 | `make test` | Go race test와 설정 검증 성공 |
| 전체 배포 | `make deploy` | Helm release와 두 Deployment rollout 성공 |
| 알림 재현 | `make load` | `cpu-load` Job이 `Complete` |
| 로컬 알림 수신 확인 | `make verify-alert` | receiver 로그에 `PodCpuSaturation` |
| Chaos Toolkit 설치·정의 점검 | `make chaos-validate` | 두 실험이 Chaos Toolkit validation 통과 |
| demo Pod 종료 복구 | `make chaos-demo` | Journal completed, `cpu-workload` 6/6 available |
| Kafka consumer 종료 복구 | `make chaos-kafka-consumer` | Journal completed, k6 성공, consumer lag 0, DB 100만 고유 행 |

## GitOps 및 Argo CD

Phase 1의 Argo CD Application은 `platform-monitoring`, `baro-demo`, `kafka-benchmark` 세 개입니다. Argo CD 설치와 Namespace 생성은 bootstrap이 담당하고, Application은 장기 실행 리소스만 관리합니다.

최초 설정 또는 새 로컬 클러스터에서는 다음 순서로 실행합니다.

```sh
make argocd-preflight
make argocd-bootstrap
make deploy
make benchmark-deploy
```

`make argocd-bootstrap`은 현재 `rancher-desktop` context에 Argo CD를 설치하고, `gitops/argocd/bootstrap/namespaces.yaml`의 Namespace를 만든 뒤 `platform-monitoring`을 먼저 동기화합니다. monitoring이 Synced/Healthy가 된 뒤 `baro-demo`와 `kafka-benchmark`를 등록합니다.

GitHub Actions는 main 변경을 SHA 기반 GHCR 이미지로 publish하고, `gitops/baro-demo/kustomization.yaml`과 `gitops/kafka-benchmark/kustomization.yaml`을 갱신하는 PR을 생성합니다. 이 PR이 merge된 후 Argo CD가 새 이미지를 배포합니다. PR 검증에서는 GHCR publish와 Kubernetes 변경을 수행하지 않습니다.

Application 상태는 다음 명령으로 확인합니다.

```sh
make argocd-status
make argocd-sync APP=baro-demo
make argocd-sync APP=kafka-benchmark
```

`postgres-auth`는 Git에 저장하지 않고 `make argocd-benchmark-secret`이 로컬 Namespace에 생성합니다. Secret 값은 출력하거나 로그에 남기지 않습니다. `benchmark-reset`, k6 load, `benchmark-verify`는 데이터 변경·검증용 실행 Job이므로 Argo CD 자동 Sync 대상이 아닙니다.

`selfHeal`이 활성화되어 클러스터에서 직접 Deployment를 변경하면 Git 상태로 되돌아갑니다. 정리 전에 `make argocd-teardown CONFIRM=teardown`으로 세 Application의 자동 Sync를 중지하고, StatefulSet·PVC·Namespace 삭제는 별도 명시적 승인 후 실행합니다.

## 배포 후 확인

```sh
kubectl --context rancher-desktop get pods -n monitoring
kubectl --context rancher-desktop get pods -n demo
kubectl --context rancher-desktop get pods -n alerting
kubectl --context rancher-desktop get alertmanager -n monitoring monitoring-kube-prometheus-alertmanager
```

정상 상태라면 Alertmanager, Grafana, Prometheus와 6개의 `cpu-workload` Pod가 `Running`이어야 합니다. 완료된 `cpu-load` Job은 `Completed` 상태가 정상입니다.

## 알림 전체 흐름 검증

1. 별도 터미널에서 `make alertmanager`를 실행합니다.
2. `make load`를 실행합니다.
3. 약 2분 뒤 Grafana의 **CPU saturation 80%** 패널 또는 Alertmanager UI에서 firing을 확인합니다.
4. `make verify-alert`로 로컬 receiver 전달을 확인합니다.
5. Job이 끝난 뒤 Alertmanager UI 또는 receiver 로그에서 resolved를 확인합니다.

로컬 receiver의 최근 payload만 확인하려면 다음을 실행합니다.

```sh
kubectl --context rancher-desktop logs -n alerting deploy/alert-receiver --tail=100
```

## Slack 연동 점검

Slack을 활성화한 뒤 다음 리소스가 있어야 합니다.

```sh
kubectl --context rancher-desktop get secret -n monitoring slack-webhook-url
kubectl --context rancher-desktop get alertmanagerconfig -n monitoring slack-notifications
```

Secret 값은 출력하지 않습니다. Slack 채널은 Incoming Webhook을 생성할 때 선택한 채널이 기준입니다. Webhook이 향하는 채널과 `gitops/platform-monitoring/optional/slack-alertmanagerconfig.yaml`의 의도를 일치시켜야 합니다.

## 문제 해결

### Slack 링크가 `*.monitoring:9093`으로 시작한다

이 링크는 클러스터 내부 DNS이므로 호스트 브라우저에서 열리지 않습니다. `gitops/platform-monitoring/values.yaml`에 `externalUrl: http://localhost:19093`이 있어야 하며, Argo CD에서 `platform-monitoring`을 다시 동기화합니다.

```sh
make monitoring-up
make alertmanager
```

`make alertmanager`를 실행한 터미널이 열려 있는 동안 새 Slack 알림의 `localhost:19093` 링크를 사용합니다. 이미 발송된 메시지는 과거 링크를 유지합니다.

### Slack 메시지가 오지 않는다

1. `SLACK_WEBHOOK_URL`을 전달해 `make enable-slack`을 실행했는지 확인합니다.
2. `slack-webhook-url` Secret과 `slack-notifications` AlertmanagerConfig가 존재하는지 확인합니다.
3. Alert rule이 `severity: warning`을 가지는지 확인합니다.
4. Workspace 관리 정책, 선택한 채널의 앱 설치 권한, Webhook 폐기 여부를 Slack에서 확인합니다.

Webhook URL은 노출되면 새 URL을 만들고 `make enable-slack`을 다시 실행합니다.

## Chaos 대시보드 판정

두 dashboard는 왼쪽에서 오른쪽으로 **Traffic → Saturation → Latency → Errors**를 표시합니다. Chaos Journal과 rollout 상태를 보기 전에 이 네 신호로 영향과 복구 추세를 확인합니다.

| 워크플로우 | Traffic | Saturation | Latency | Errors/결과 |
| --- | --- | --- | --- | --- |
| demo Pod 종료 | completed 요청률이 회복 | Pod CPU/limit이 80% target을 넘는지 | CPU-work p95/p99 | `rejected`, `cancelled`가 원인을 설명하는지 |
| Kafka consumer 종료 | acknowledged 이벤트율이 유지 | consumer backlog가 0으로 회복 | E2E p95/p99가 안정화 | HTTP reject·publish failure는 0, `idempotently suppressed`는 멱등 처리 결과 |

Grafana의 시계열은 scrape interval에 따라 늦게 보일 수 있으므로, 최종 Kafka 정합성 판정은 항상 `make benchmark-verify`의 100만 고유 행 및 consumer group lag 0 결과를 사용합니다.

## Chaos Toolkit 실험 운영

실험은 호스트 가상환경에서 실행되며 `rancher-desktop` context를 고정 사용합니다. `CONTEXT`를 다른 값으로 지정하면 Chaos target은 리소스를 만들기 전에 종료하므로, 부하 생성과 장애 주입이 서로 다른 클러스터로 향하지 않습니다. 실행 전에는 대상 서비스가 이미 정상인지 확인하고, 실행 결과는 `chaos/reports/`의 Journal과 Kubernetes 상태를 함께 판정합니다. Slack 수신은 보조 관측이며 성공 기준은 아닙니다.

### cpu-workload Pod 종료

```sh
make deploy
make chaos-demo
kubectl --context rancher-desktop -n demo get deployment cpu-workload
```

성공은 Journal의 before/after steady-state가 모두 통과하고 `cpu-workload`의 available replica가 6인 경우입니다. 종료된 Pod 이름은 Journal method action에 기록됩니다.

### 처리 중 Kafka consumer Pod 종료

```sh
make benchmark-deploy
make chaos-kafka-consumer
```

이 명령은 기존 benchmark Job을 교체하므로 다른 benchmark 실행과 동시에 시작하지 않습니다. consumer Deployment와 ingest Deployment가 사전에 정상이어야 하며, 종료 대상은 consumer label selector로 제한됩니다. 완료 후 `make benchmark-verify`가 자동 실행되어 Kafka consumer group lag `0` 및 PostgreSQL의 100만 고유 event를 판정합니다.

실험 도중 중단했다면 다음으로 controller 복구와 남은 load Job 상태를 확인합니다.

```sh
kubectl --context rancher-desktop -n kafka-benchmark rollout status deployment/consumer --timeout=3m
kubectl --context rancher-desktop -n kafka-benchmark get job kafka-benchmark-load
```

Kafka와 PostgreSQL은 모두 단일 복제본이므로 이 실습의 Chaos Toolkit 케이스에서는 종료 대상으로 삼지 않습니다. 해당 장애는 가용성 복원력 통과가 아니라 의도된 서비스 단절을 관찰하는 별도 시나리오입니다.

### Alert가 firing하지 않는다

```sh
kubectl --context rancher-desktop get job -n demo cpu-load
kubectl --context rancher-desktop get servicemonitor -n demo cpu-workload
kubectl --context rancher-desktop get prometheusrule -n monitoring pod-cpu-saturation
```

`cpu-load`가 완료됐는지, ServiceMonitor와 PrometheusRule이 존재하는지 먼저 확인합니다. 그다음 Grafana의 CPU panel에서 Pod별 CPU 비율이 80%를 넘고 2분 이상 유지됐는지 확인합니다.

### Prometheus 또는 Alertmanager가 재배포 중 실패한다

```sh
kubectl --context rancher-desktop describe alertmanager -n monitoring monitoring-kube-prometheus-alertmanager
kubectl --context rancher-desktop describe prometheus -n monitoring monitoring-kube-prometheus-prometheus
kubectl --context rancher-desktop get events -n monitoring --sort-by=.lastTimestamp
```

이 프로젝트는 Prometheus CRD의 최소값 제약을 충족하도록 `maximumStartupDurationSeconds: 900`을 설정합니다. Alertmanager 기본 route의 `null` receiver도 `gitops/platform-monitoring/values.yaml`에 유지해야 합니다.

## Kafka 벤치마크가 10분 내 완료되지 않는다

`make benchmark-run`의 k6 Job 로그에서 완료 iteration, HTTP 실패율, threshold 결과를 확인합니다. 그다음 `make benchmark-verify`로 PostgreSQL의 정확한 100만 고유 행과 consumer lag를 검사합니다. 기준 시간 초과는 로컬 4 vCPU/단일 노드 환경의 측정 결과이며, iteration 수나 10분 기준을 낮춰 통과로 처리하지 않습니다.

consumer 재시작 횟수와 Kafka·PostgreSQL Pod 상태는 다음 명령으로 확인합니다.

```sh
kubectl --context rancher-desktop -n kafka-benchmark get pods
kubectl --context rancher-desktop -n kafka-benchmark logs deployment/consumer --tail=100
kubectl --context rancher-desktop -n kafka-benchmark logs job/kafka-benchmark-load --tail=100
```

## 정리와 재배포

```sh
make teardown
make deploy
```

`teardown`은 이 실습의 namespace 및 Helm release만 제거합니다. 기존 Rancher Desktop 워크로드나 설정은 삭제하지 않습니다.
