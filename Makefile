SHELL := /bin/sh

CONTEXT ?= rancher-desktop
IMAGE ?= k8s-monitoring-lab:dev
KUBECTL := kubectl --context $(CONTEXT)
HELM := helm
NERDCTL := nerdctl --namespace k8s.io

.PHONY: preflight test build-image monitoring-up app-up deploy load verify-alert dashboard alertmanager enable-slack teardown

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
