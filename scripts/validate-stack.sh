#!/bin/sh
set -eu

grep -q '^    maximumStartupDurationSeconds: 900$' monitoring/values.yaml
grep -q '^      - name: "null"$' monitoring/values.yaml
grep -q '^      org_role: Viewer$' monitoring/values.yaml
grep -q '^    externalUrl: http://localhost:19093$' monitoring/values.yaml
