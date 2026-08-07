#!/bin/sh
set -eu

grep -q '^    maximumStartupDurationSeconds: 900$' monitoring/values.yaml
grep -q '^      - name: "null"$' monitoring/values.yaml
grep -q '^      org_role: Viewer$' monitoring/values.yaml
grep -q '^    externalUrl: http://localhost:19093$' monitoring/values.yaml
grep -q '^  name: kafka-benchmark$' k8s/kafka-benchmark.yaml
grep -q '^          iterations: 1000000,$' load/k6-benchmark-job.yaml
grep -q '^          maxDuration: '\''10m'\'',$' load/k6-benchmark-job.yaml
grep -q '^      event_id BIGINT PRIMARY KEY,$' k8s/kafka-benchmark.yaml
grep -q '^benchmark-up: monitoring-up$' Makefile
grep -q '^benchmark-deploy: preflight test build-image benchmark-up$' Makefile
grep -q 'rollout restart deployment/ingest deployment/consumer' Makefile
