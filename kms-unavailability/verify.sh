#!/bin/bash
# Polls for the kms-unavailable alert in the webhook receiver and Kafka.
# The KMS monitor runs every 5 minutes; this script waits up to 10 minutes.
set -euo pipefail

PASS=0
FAIL=0
ALERT_TYPE="kms-unavailable"
MAX_WAIT_SECONDS=600   # 10 minutes
POLL_INTERVAL=20

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== KMS Unavailability Alert - Verification ==="
echo "  Waiting up to $((MAX_WAIT_SECONDS / 60)) minutes for alert type: $ALERT_TYPE"
echo ""

# --- Poll webhook until the alert arrives ---
echo "--- Polling webhook receiver ---"
FOUND_WH=false
ELAPSED=0
while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
    ALERT_COUNT=$(
        curl -sf "http://localhost:9090/entries" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    count = sum(1 for e in entries if isinstance(e, dict) and e.get('type') == '$ALERT_TYPE')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0"
    )
    if [ "${ALERT_COUNT:-0}" -gt 0 ]; then
        FOUND_WH=true
        break
    fi
    echo -n "."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
echo ""

if $FOUND_WH; then
    pass "kms-unavailable alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No kms-unavailable alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

# --- Check Kafka ---
echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka-kms kafka-console-consumer \
        --bootstrap-server localhost:29092 \
        --topic alert-events \
        --from-beginning \
        --timeout-ms 8000 2>/dev/null \
    | python3 -c "
import sys
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    import json
    try:
        d = json.loads(line)
        if d.get('type') == '$ALERT_TYPE':
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0"
)

if [ "${KAFKA_COUNT:-0}" -gt 0 ]; then
    pass "kms-unavailable alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No kms-unavailable alert found in Kafka alert-events topic"
fi

echo ""

# --- Show alert detail ---
echo "--- Alert detail (from webhook) ---"
curl -sf "http://localhost:9090/entries" 2>/dev/null \
| python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == '$ALERT_TYPE']
    if alerts:
        print(json.dumps(alerts[-1], indent=2))
    else:
        print('  (none)')
except Exception as e:
    print('  (unavailable: ' + str(e) + ')')
" 2>/dev/null || echo "  (unavailable)"

echo ""

# --- Verify alert details ---
echo "--- Checking alert content ---"
DETAIL=$(
    curl -sf "http://localhost:9090/entries" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == '$ALERT_TYPE']
    if alerts:
        a = alerts[-1]
        title = a.get('title', '')
        kms_type = a.get('details', {}).get('kmsType', '')
        dedup = a.get('dedupKey', '')
        print(title + '|' + kms_type + '|' + dedup)
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL" | cut -d'|' -f1)
    KMS_TYPE=$(echo "$DETAIL" | cut -d'|' -f2)
    DEDUP=$(echo "$DETAIL" | cut -d'|' -f3)
    [ "$TITLE" = "KMS Unavailable" ] && pass "Alert title correct: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"
    [ -n "$KMS_TYPE" ] && pass "kmsType present in details: '$KMS_TYPE'" \
        || fail "kmsType missing from alert details"
    [ "$DEDUP" = "kms-unavailable" ] && pass "dedupKey correct: '$DEDUP'" \
        || fail "Unexpected dedupKey: '$DEDUP'"
else
    fail "Could not parse alert details"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
