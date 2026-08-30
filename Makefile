SHELL := /bin/sh

CONTEXT ?= rancher-desktop
IMAGE ?= k8s-monitoring-lab:dev
KUBECTL := kubectl --context $(CONTEXT)
HELM := helm
NERDCTL := nerdctl --namespace k8s.io
CHAOS := chaos/.venv/bin/chaos
CHAOS_PIP := chaos/.venv/bin/pip
CHAOS_REPORTS := chaos/reports

.PHONY: preflight test build-image monitoring-up app-up deploy load verify-alert dashboard alertmanager enable-slack teardown benchmark-secrets benchmark-up benchmark-deploy benchmark-load-start benchmark-load-wait benchmark-run benchmark-verify benchmark-dashboard benchmark-down argocd-preflight argocd-bootstrap argocd-status argocd-sync argocd-benchmark-secret argocd-teardown chaos-context chaos-setup chaos-validate chaos-run chaos-demo chaos-kafka-consumer

preflight:
	@$(KUBECTL) get nodes
	@$(HELM) version --short
	@$(NERDCTL) version >/dev/null

test:
	@go test -race -shuffle=on -count=1 ./...
	@sh scripts/validate-stack.sh

build-image:
	@$(NERDCTL) build -t $(IMAGE) .

monitoring-up:
	@$(MAKE) argocd-bootstrap

app-up:
	@$(MAKE) argocd-sync APP=baro-demo

argocd-preflight:
	@bash scripts/argocd.sh preflight

argocd-bootstrap:
	@bash scripts/argocd.sh bootstrap

argocd-status:
	@bash scripts/argocd.sh status

argocd-sync:
	@test -n "$(APP)"
	@bash scripts/argocd.sh sync "$(APP)"

argocd-benchmark-secret:
	@bash scripts/argocd.sh benchmark-secret

argocd-teardown:
	@test "$(CONFIRM)" = "teardown" || (echo 'Set CONFIRM=teardown to suspend Argo CD applications.' >&2; exit 1)
	@bash scripts/argocd.sh suspend

deploy: test argocd-bootstrap
	@bash scripts/argocd.sh sync baro-demo

load:
	@$(KUBECTL) --namespace demo delete job cpu-load --ignore-not-found
	@$(KUBECTL) apply -f load/k6-job.yaml
	@$(KUBECTL) --namespace demo wait --for=condition=complete job/cpu-load --timeout=8m

verify-alert:
	@$(KUBECTL) --namespace alerting logs deployment/alert-receiver --tail=100 | grep -q 'PodCpuSaturation'
	@echo 'Local Alertmanager webhook delivery verified.'

dashboard:
	@echo 'Grafana: kubectl --context $(CONTEXT) --namespace monitoring port-forward svc/monitoring-grafana 3000:80'

alertmanager:
	@$(KUBECTL) --namespace monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 19093:9093

enable-slack:
	@sh scripts/enable-slack.sh

teardown:
	@$(MAKE) argocd-teardown CONFIRM="$(CONFIRM)"

benchmark-secrets:
	@$(MAKE) argocd-benchmark-secret

benchmark-up: argocd-bootstrap argocd-benchmark-secret
	@bash scripts/argocd.sh sync kafka-benchmark

benchmark-deploy: test argocd-bootstrap argocd-benchmark-secret
	@bash scripts/argocd.sh sync kafka-benchmark

benchmark-load-start:
	@$(KUBECTL) --namespace kafka-benchmark delete job benchmark-reset kafka-benchmark-load --ignore-not-found
	@$(KUBECTL) apply -f k8s/benchmark-reset-job.yaml
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/benchmark-reset --timeout=2m
	@$(KUBECTL) apply -f load/k6-benchmark-job.yaml
	@deadline=$$(($$(date +%s) + 120)); \
	while [ "$$(date +%s)" -lt "$$deadline" ]; do \
		active=$$($(KUBECTL) --namespace kafka-benchmark get job kafka-benchmark-load -o jsonpath='{.status.active}'); \
		[ "$$active" = "1" ] && exit 0; \
		sleep 2; \
	done; \
	echo 'kafka-benchmark-load did not become active within 120 seconds.' >&2; \
	exit 1

benchmark-load-wait:
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/kafka-benchmark-load --timeout=11m

benchmark-run: benchmark-load-start
	@$(MAKE) benchmark-load-wait

benchmark-verify:
	@$(KUBECTL) --namespace kafka-benchmark delete job benchmark-verify --ignore-not-found
	@$(KUBECTL) apply -f k8s/benchmark-verify-job.yaml
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/benchmark-verify --timeout=12m
	@$(KUBECTL) --namespace kafka-benchmark exec statefulset/kafka -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka.kafka-benchmark.svc.cluster.local:9092 --describe --group benchmark-consumers | awk 'NR > 1 && $$6 != "-" { lag += $$6 } END { exit (lag == 0 ? 0 : 1) }'
	@echo 'Kafka consumer lag is zero and PostgreSQL contains exactly 1,000,000 unique events.'

benchmark-dashboard:
	@echo 'Grafana: kubectl --context $(CONTEXT) --namespace monitoring port-forward svc/monitoring-grafana 3000:80'

benchmark-down:
	@test "$(CONFIRM)" = "teardown" || (echo 'Set CONFIRM=teardown to remove kafka-benchmark.' >&2; exit 1)
	@$(MAKE) argocd-teardown CONFIRM=teardown
	@$(KUBECTL) delete namespace kafka-benchmark --ignore-not-found

chaos-context:
	@test "$(CONTEXT)" = "rancher-desktop" || (echo 'Chaos experiments only support CONTEXT=rancher-desktop.' >&2; exit 2)

chaos-setup:
	@test -x $(CHAOS) || python3 -m venv chaos/.venv
	@$(CHAOS_PIP) install --disable-pip-version-check --no-input --requirement chaos/requirements.txt

chaos-validate: chaos-setup
	@for experiment in chaos/experiments/*.json; do $(CHAOS) validate "$$experiment"; done

chaos-run: chaos-context chaos-setup
	@test -n "$(EXPERIMENT)" || (echo 'Set EXPERIMENT to a Chaos Toolkit experiment path.' >&2; exit 2)
	@mkdir -p $(CHAOS_REPORTS)
	@$(CHAOS) run "$(EXPERIMENT)" --journal-path "$(CHAOS_REPORTS)/$$(basename "$(EXPERIMENT)" .json)-$$(date -u +%Y%m%dT%H%M%SZ).json"

chaos-demo: chaos-context chaos-validate
	@$(MAKE) chaos-run EXPERIMENT=chaos/experiments/cpu-workload-pod-termination.json

chaos-kafka-consumer: chaos-context chaos-validate
	@$(MAKE) benchmark-load-start
	@if ! $(MAKE) chaos-run EXPERIMENT=chaos/experiments/kafka-consumer-pod-termination.json; then \
		echo 'Chaos experiment failed; completing the started benchmark for recovery evidence.' >&2; \
		$(MAKE) benchmark-load-wait; \
		$(MAKE) benchmark-verify; \
		exit 1; \
	fi
	@$(MAKE) benchmark-load-wait
	@$(MAKE) benchmark-verify
