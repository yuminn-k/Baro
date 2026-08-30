#!/bin/sh
set -eu

grep -q '^    maximumStartupDurationSeconds: 900$' gitops/platform-monitoring/values.yaml
grep -q '^      - name: "null"$' gitops/platform-monitoring/values.yaml
grep -q '^      org_role: Viewer$' gitops/platform-monitoring/values.yaml
grep -q '^    externalUrl: http://localhost:19093$' gitops/platform-monitoring/values.yaml
grep -q '^  name: kafka-benchmark$' gitops/argocd/bootstrap/namespaces.yaml
grep -q '^          iterations: 1000000,$' load/k6-benchmark-job.yaml
grep -q '^          maxDuration: '\''10m'\'',$' load/k6-benchmark-job.yaml
grep -q '^              cpu: 100m$' load/k6-benchmark-job.yaml
grep -q '^      event_id BIGINT PRIMARY KEY,$' gitops/kafka-benchmark/resources/kafka-benchmark.yaml
grep -q -- '--alter' gitops/kafka-benchmark/resources/kafka-benchmark.yaml
grep -q 'PartitionCount:' gitops/kafka-benchmark/resources/kafka-benchmark.yaml
grep -q '^benchmark-up: argocd-bootstrap argocd-benchmark-secret$' Makefile
grep -q '^benchmark-deploy: test argocd-bootstrap argocd-benchmark-secret$' Makefile
! grep -q 'rollout restart deployment/ingest deployment/consumer' Makefile
python3 - <<'PY'
import json
from pathlib import Path


def config_map_dashboard(path: str, key: str) -> dict:
    content = Path(path).read_text()
    marker = f"  {key}: |\n"
    _, payload = content.split(marker, 1)
    return json.loads("\n".join(line[4:] for line in payload.splitlines()))


def assert_four_signals(dashboard: dict, expected_titles: list[str]) -> None:
    panels = dashboard["panels"]
    assert [panel["title"] for panel in panels] == expected_titles
    assert [(panel["gridPos"]["x"], panel["gridPos"]["y"], panel["gridPos"]["w"]) for panel in panels] == [
        (0, 0, 6),
        (6, 0, 6),
        (12, 0, 6),
        (18, 0, 6),
    ]


demo = config_map_dashboard("gitops/platform-monitoring/resources/configmap.yaml", "k8s-monitoring-lab.json")
kafka = config_map_dashboard("gitops/platform-monitoring/resources/kafka-benchmark-configmap.yaml", "kafka-benchmark.json")

assert_four_signals(demo, ["Traffic", "CPU saturation 80%", "Latency", "Errors"])
assert_four_signals(kafka, ["Traffic", "Saturation (backlog)", "Latency", "Errors & Idempotency"])
assert json.loads(Path("dashboards/cpu-workload.json").read_text()) == demo

demo_targets = [target["expr"] for panel in demo["panels"] for target in panel["targets"]]
assert any("cpu_work_requests_total" in target and "$__rate_interval" in target for target in demo_targets)
assert any("cpu_work_request_duration_seconds_bucket" in target and "histogram_quantile(0.99" in target for target in demo_targets)
assert any('outcome=~"rejected|cancelled"' in target for target in demo_targets)
assert any(target == "vector(0.8)" for target in demo_targets)
assert demo["panels"][1]["fieldConfig"]["defaults"]["thresholds"]["steps"][1]["value"] == 0.8
assert demo["panels"][1]["fieldConfig"]["defaults"]["thresholdsStyle"]["mode"] == "area+line"
assert demo["panels"][1]["fieldConfig"]["defaults"]["min"] == 0
assert demo["panels"][1]["fieldConfig"]["defaults"]["max"] == 1

kafka_targets = [target for panel in kafka["panels"] for target in panel["targets"]]
assert any("benchmark_event_end_to_end_seconds_bucket" in target["expr"] and "histogram_quantile(0.99" in target["expr"] for target in kafka_targets)
assert {target["legendFormat"] for target in kafka["panels"][3]["targets"]} == {
    "HTTP rejected",
    "publish failed",
    "inserted",
    "deduplicated",
}
PY

sh scripts/validate-gitops.sh
