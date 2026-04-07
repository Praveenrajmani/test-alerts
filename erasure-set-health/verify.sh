set -euo pipefail

PASS=0
FAIL=0
ALERT_TYPE="erasure-set-health"
MAX_WAIT_SECONDS=300   # 5 minutes
POLL_INTERVAL=15

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Erasure Set Health Alert - Verification ==="
echo "  Waiting up to $((MAX_WAIT_SECONDS / 60)) minutes for alert type: $ALERT_TYPE"
echo ""

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
    pass "erasure-set-health alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No erasure-set-health alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka-erasure kafka-console-consumer \
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
    pass "erasure-set-health alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No erasure-set-health alert found in Kafka alert-events topic"
fi

echo ""

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
        d = a.get('details', {})
        fields = [
            a.get('title', ''),
            d.get('condition', ''),
            d.get('onlineDrives', ''),
            d.get('totalDrives', ''),
            d.get('writeQuorum', ''),
            a.get('dedupKey', ''),
        ]
        print('|'.join(str(f) for f in fields))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL"        | cut -d'|' -f1)
    CONDITION=$(echo "$DETAIL"    | cut -d'|' -f2)
    ONLINE=$(echo "$DETAIL"       | cut -d'|' -f3)
    TOTAL=$(echo "$DETAIL"        | cut -d'|' -f4)
    WQ=$(echo "$DETAIL"           | cut -d'|' -f5)
    DEDUP=$(echo "$DETAIL"        | cut -d'|' -f6)

    echo "$TITLE" | grep -q "Erasure Set" \
        && pass "Alert title references erasure set: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"

    [ -n "$CONDITION" ] \
        && pass "condition present in details: '$CONDITION'" \
        || fail "condition missing from alert details"

    [ -n "$ONLINE" ] && [ -n "$TOTAL" ] && [ -n "$WQ" ] \
        && pass "drive counts present: online=$ONLINE total=$TOTAL writeQuorum=$WQ" \
        || fail "drive count fields missing (online='$ONLINE' total='$TOTAL' wq='$WQ')"

    IS_DEGRADED=$(python3 -c "
online = int('${ONLINE:-0}')
total  = int('${TOTAL:-0}')
print('yes' if total > 0 and online < total else 'no')
" 2>/dev/null || echo "no")
    [ "$IS_DEGRADED" = "yes" ] \
        && pass "cluster is degraded: $ONLINE of $TOTAL drives online" \
        || fail "drive counts do not indicate degradation (online=$ONLINE total=$TOTAL)"

    echo "$DEDUP" | grep -q "erasure-set-health" \
        && pass "dedupKey references erasure-set-health: '$DEDUP'" \
        || fail "Unexpected dedupKey: '$DEDUP'"
else
    fail "Could not parse alert details"
fi

echo ""

# shellcheck source=../verify-mc.sh
source "$(dirname "$0")/../verify-mc.sh"
check_mc_alerts "$ALERT_TYPE" "http://localhost:9010"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
