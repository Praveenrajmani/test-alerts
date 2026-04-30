set -euo pipefail

PASS=0
FAIL=0
ALERT_TYPE="license-expiry"
MAX_WAIT_SECONDS=300   # 5 minutes; alert fires on first monitor check after startup
POLL_INTERVAL=15

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== License Expiry Alert - Verification ==="
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
    pass "license-expiry alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No license-expiry alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka-license kafka-console-consumer \
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
    pass "license-expiry alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No license-expiry alert found in Kafka alert-events topic"
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
            d.get('state', ''),
            d.get('licenseId', ''),
            d.get('expiresAt', ''),
            a.get('dedupKey', ''),
        ]))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL"     | cut -d'|' -f1)
    STATE=$(echo "$DETAIL"     | cut -d'|' -f2)
    LICENSE_ID=$(echo "$DETAIL" | cut -d'|' -f3)
    EXPIRES_AT=$(echo "$DETAIL" | cut -d'|' -f4)
    DEDUP=$(echo "$DETAIL"     | cut -d'|' -f5)

    echo "$TITLE" | grep -qiE "license|expir|grace" \
        && pass "Alert title references license expiry: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"

    case "$STATE" in
        grace_period|fully_expired)
            pass "state is a valid license expiry state: '$STATE'"
            ;;
        *)
            fail "Unexpected state: '$STATE' (want 'grace_period' or 'fully_expired')"
            ;;
    esac

    [ -n "$EXPIRES_AT" ] \
        && pass "expiresAt present in details: '$EXPIRES_AT'" \
        || fail "expiresAt missing from alert details"

    echo "$DEDUP" | grep -qE "^license:.+:(grace_period|fully_expired)$" \
        && pass "dedupKey has correct format: '$DEDUP'" \
        || fail "Unexpected dedupKey: '$DEDUP'"
else
    fail "Could not parse alert details"
fi

echo ""

source "$(dirname "$0")/../verify-mc.sh"
check_mc_alerts "$ALERT_TYPE" "http://localhost:9010"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
