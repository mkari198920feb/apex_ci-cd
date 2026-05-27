#!/bin/bash
# Post-deploy smoke check. Verifies the APEX app responds and login page renders.

set -euo pipefail

APEX_URL="${1:-}"
if [ -z "${APEX_URL}" ]; then
    echo "Usage: smoke_check.sh <apex-url>"
    exit 1
fi

echo "==> Smoke checking ${APEX_URL}"

# 1. HTTP reachability
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 30 "${APEX_URL}")
if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "302" ]; then
    echo "FAIL: HTTP ${HTTP_CODE} from ${APEX_URL}"
    exit 1
fi
echo "  OK: HTTP ${HTTP_CODE}"

# 2. Look for APEX markers in the response body
BODY=$(curl -sS --max-time 30 "${APEX_URL}")
if ! echo "${BODY}" | grep -qi "apex"; then
    echo "FAIL: response does not look like an APEX page"
    exit 1
fi
echo "  OK: APEX markers present"

# 3. Latency budget
LATENCY=$(curl -sS -o /dev/null -w "%{time_total}" --max-time 30 "${APEX_URL}")
echo "  Latency: ${LATENCY}s"

LATENCY_MS=$(awk "BEGIN {printf \"%d\", ${LATENCY} * 1000}")
if [ "${LATENCY_MS}" -gt 5000 ]; then
    echo "WARN: latency above 5s budget"
fi

echo "==> Smoke check passed"
