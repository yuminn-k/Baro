# 운영 및 검증 가이드

## 일상 명령

| 상황 | 명령 | 성공 기준 |
| --- | --- | --- |
| 클러스터 연결 확인 | `make preflight` | Rancher Desktop 노드가 `Ready` |
| 코드와 필수 설정 확인 | `make test` | Go race test와 설정 검증 성공 |
| 전체 배포 | `make deploy` | Helm release와 두 Deployment rollout 성공 |
| 알림 재현 | `make load` | `cpu-load` Job이 `Complete` |
| 로컬 알림 수신 확인 | `make verify-alert` | receiver 로그에 `PodCpuSaturation` |

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
