#!/bin/bash
set -e

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== MinIO Alert Targets - Verification ==="
echo ""

# --- Webhook Stats ---
echo "--- Webhook Receiver ---"
STATS=$(curl -sf http://localhost:9090/stats 2>/dev/null) || true
if [ -n "$STATS" ]; then
    ALERT_WH=$(echo "$STATS" | python3 -c "import sys,json; print(json.load(sys.stdin)['alerts_received'])" 2>/dev/null || echo "0")

    if [ "$ALERT_WH" -gt 0 ] 2>/dev/null; then
        pass "Alerts received via webhook: $ALERT_WH"
    else
        fail "No alerts received via webhook"
    fi
else
    fail "Cannot reach webhook receiver at http://localhost:9090/stats"
fi

echo ""

# --- Kafka Topic ---
echo "--- Kafka Topic ---"

echo "  Checking alert-events topic..."
ALERT_KAFKA=$(docker exec kafka kafka-console-consumer \
    --bootstrap-server localhost:29092 \
    --topic alert-events \
    --from-beginning \
    --timeout-ms 5000 2>/dev/null | wc -l || echo "0")

if [ "$ALERT_KAFKA" -gt 0 ] 2>/dev/null; then
    pass "Alerts in Kafka: $ALERT_KAFKA messages"
else
    fail "No alerts in Kafka alert-events topic"
fi

echo ""

# --- Sample Entries ---
echo "--- Sample Alert Entries ---"
echo ""

echo "Last alert entry (webhook):"
curl -sf "http://localhost:9090/entries" 2>/dev/null | python3 -c "
import sys, json
entries = json.load(sys.stdin)
if entries:
    print(json.dumps(entries[-1], indent=2)[:800])
else:
    print('  (none)')
" 2>/dev/null || echo "  (unavailable)"

echo ""

echo "Last alert entry (Kafka):"
docker exec kafka kafka-console-consumer \
    --bootstrap-server localhost:29092 \
    --topic alert-events \
    --from-beginning \
    --timeout-ms 3000 2>/dev/null | tail -1 | python3 -m json.tool 2>/dev/null | head -30 || echo "  (unavailable)"

echo ""

# shellcheck source=verify-mc.sh
source "$(dirname "$0")/verify-mc.sh"
check_mc_alerts "certificate-expiry" "https://localhost:9010" "--insecure"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
