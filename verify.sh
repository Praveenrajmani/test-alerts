set -euo pipefail

PASS=0
FAIL=0
ALERT_TYPE="certificate-expiry"
MAX_WAIT_SECONDS=300   # 5 minutes; alert fires immediately on leader election
POLL_INTERVAL=15

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== TLS Certificate Expiry Alert - Verification ==="
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
    pass "certificate-expiry alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No certificate-expiry alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka kafka-console-consumer \
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
    pass "certificate-expiry alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No certificate-expiry alert found in Kafka alert-events topic"
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
        print('|'.join([
            a.get('title', ''),
            d.get('daysUntilExpiry', ''),
            d.get('commonName', ''),
            a.get('dedupKey', ''),
        ]))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL"   | cut -d'|' -f1)
    DAYS=$(echo "$DETAIL"    | cut -d'|' -f2)
    CN=$(echo "$DETAIL"      | cut -d'|' -f3)
    DEDUP=$(echo "$DETAIL"   | cut -d'|' -f4)

    echo "$TITLE" | grep -qiE "expir" \
        && pass "Alert title references expiry: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"

    [ -n "$CN" ] \
        && pass "commonName present: '$CN'" \
        || fail "commonName missing from alert details"

    [ -n "$DAYS" ] \
        && pass "daysUntilExpiry present: $DAYS day(s)" \
        || fail "daysUntilExpiry missing from alert details"

    echo "$DEDUP" | grep -q "cert:" \
        && pass "dedupKey references cert: '$DEDUP'" \
        || fail "Unexpected dedupKey: '$DEDUP'"
else
    fail "Could not parse alert details"
fi

echo ""

# shellcheck source=verify-mc.sh
source "$(dirname "$0")/verify-mc.sh"
check_mc_alerts "$ALERT_TYPE" "https://localhost:9010" "--insecure"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
