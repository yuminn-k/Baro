SHELL := /bin/sh

CONTEXT ?= rancher-desktop
IMAGE ?= k8s-monitoring-lab:dev
KUBECTL := kubectl --context $(CONTEXT)
HELM := helm
NERDCTL := nerdctl --namespace k8s.io

.PHONY: preflight test build-image monitoring-up app-up deploy load verify-alert dashboard alertmanager enable-slack teardown benchmark-secrets benchmark-up benchmark-deploy benchmark-run benchmark-verify benchmark-dashboard benchmark-down

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
	@$(HELM) upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace --version 88.1.3 \
		--values monitoring/values.yaml --wait --timeout 10m

app-up:
	@$(KUBECTL) apply -f k8s/namespaces.yaml
	@$(KUBECTL) apply -f k8s/workload.yaml
	@$(KUBECTL) apply -f k8s/alert-receiver.yaml
	@$(KUBECTL) apply -f dashboards/configmap.yaml
	@$(KUBECTL) apply -f alerts/pod-cpu-saturation.yaml
	@$(KUBECTL) --namespace demo rollout restart deployment/cpu-workload
	@$(KUBECTL) --namespace demo rollout status deployment/cpu-workload --timeout=3m
	@$(KUBECTL) --namespace alerting rollout status deployment/alert-receiver --timeout=3m

deploy: preflight test build-image monitoring-up app-up

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
	@$(KUBECTL) delete namespace demo alerting --ignore-not-found
	@$(HELM) uninstall monitoring --namespace monitoring || true

benchmark-secrets:
	@if $(KUBECTL) --namespace kafka-benchmark get secret postgres-auth >/dev/null 2>&1; then exit 0; fi; \
	benchmark_password=$$(openssl rand -hex 24); \
	$(KUBECTL) --namespace kafka-benchmark create secret generic postgres-auth \
		--from-literal=password="$$benchmark_password" \
		--from-literal=url="postgres://benchmark:$$benchmark_password@postgres.kafka-benchmark.svc.cluster.local:5432/benchmark?sslmode=disable" \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

benchmark-up: monitoring-up
	@$(KUBECTL) apply -f k8s/kafka-benchmark.yaml
	@$(MAKE) benchmark-secrets
	@$(KUBECTL) --namespace kafka-benchmark rollout status statefulset/kafka --timeout=5m
	@$(KUBECTL) --namespace kafka-benchmark rollout status statefulset/postgres --timeout=5m
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/kafka-topic --timeout=5m
	@$(KUBECTL) --namespace kafka-benchmark rollout status deployment/ingest --timeout=3m
	@$(KUBECTL) --namespace kafka-benchmark rollout status deployment/consumer --timeout=3m
	@$(KUBECTL) apply -f dashboards/kafka-benchmark-configmap.yaml

benchmark-deploy: preflight test build-image benchmark-up
	@$(KUBECTL) --namespace kafka-benchmark rollout restart deployment/ingest deployment/consumer
	@$(KUBECTL) --namespace kafka-benchmark rollout status deployment/ingest --timeout=3m
	@$(KUBECTL) --namespace kafka-benchmark rollout status deployment/consumer --timeout=3m

benchmark-run:
	@$(KUBECTL) --namespace kafka-benchmark delete job benchmark-reset kafka-benchmark-load --ignore-not-found
	@$(KUBECTL) apply -f k8s/benchmark-reset-job.yaml
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/benchmark-reset --timeout=2m
	@$(KUBECTL) apply -f load/k6-benchmark-job.yaml
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/kafka-benchmark-load --timeout=11m

benchmark-verify:
	@$(KUBECTL) --namespace kafka-benchmark delete job benchmark-verify --ignore-not-found
	@$(KUBECTL) apply -f k8s/benchmark-verify-job.yaml
	@$(KUBECTL) --namespace kafka-benchmark wait --for=condition=complete job/benchmark-verify --timeout=12m
	@$(KUBECTL) --namespace kafka-benchmark exec statefulset/kafka -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka.kafka-benchmark.svc.cluster.local:9092 --describe --group benchmark-consumers | awk 'NR > 1 && $$6 != "-" { lag += $$6 } END { exit (lag == 0 ? 0 : 1) }'
	@echo 'Kafka consumer lag is zero and PostgreSQL contains exactly 1,000,000 unique events.'

benchmark-dashboard:
	@echo 'Grafana: kubectl --context $(CONTEXT) --namespace monitoring port-forward svc/monitoring-grafana 3000:80'

benchmark-down:
	@$(KUBECTL) delete namespace kafka-benchmark --ignore-not-found
