#!/bin/bash
# Polls for the storage-capacity alert in the webhook receiver and Kafka.
# The alert fires on the first leader monitor run (immediately after startup).
# This script waits up to 5 minutes for it to arrive.
set -euo pipefail

PASS=0
FAIL=0
ALERT_TYPE="storage-capacity"
MAX_WAIT_SECONDS=300   # 5 minutes
POLL_INTERVAL=15

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Storage Capacity Alert - Verification ==="
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
    pass "storage-capacity alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No storage-capacity alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

# --- Check Kafka ---
echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka-storage kafka-console-consumer \
        --bootstrap-server localhost:29092 \
        --topic alert-events \
        --from-beginning \
        --timeout-ms 8000 2>/dev/null \
    | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
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
    pass "storage-capacity alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No storage-capacity alert found in Kafka alert-events topic"
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

# --- Verify alert content ---
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
        details = a.get('details', {})
        free_pct = float(details.get('freePercent', '100'))
        free_bytes = details.get('freeBytes', '')
        total_bytes = details.get('totalBytes', '')
        title = a.get('title', '')
        dedup = a.get('dedupKey', '')
        print(title + '|' + str(free_pct) + '|' + free_bytes + '|' + total_bytes + '|' + dedup)
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL" | cut -d'|' -f1)
    FREE_PCT=$(echo "$DETAIL" | cut -d'|' -f2)
    FREE_BYTES=$(echo "$DETAIL" | cut -d'|' -f3)
    TOTAL_BYTES=$(echo "$DETAIL" | cut -d'|' -f4)
    DEDUP=$(echo "$DETAIL" | cut -d'|' -f5)

    [ "$TITLE" = "Storage Capacity Critical" ] \
        && pass "Alert title correct: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"

    [ "$DEDUP" = "storage-capacity" ] \
        && pass "dedupKey correct: '$DEDUP'" \
        || fail "Unexpected dedupKey: '$DEDUP'"

    # freePercent must be < 10
    IS_LOW=$(python3 -c "print('yes' if float('${FREE_PCT:-100}') < 10.0 else 'no')" 2>/dev/null || echo "no")
    [ "$IS_LOW" = "yes" ] \
        && pass "freePercent is below 10%: ${FREE_PCT}%" \
        || fail "freePercent is not below 10% (got ${FREE_PCT}%)"

    [ -n "$FREE_BYTES" ] && [ -n "$TOTAL_BYTES" ] \
        && pass "freeBytes=$FREE_BYTES, totalBytes=$TOTAL_BYTES present in details" \
        || fail "freeBytes or totalBytes missing from alert details"
else
    fail "Could not parse alert details"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
