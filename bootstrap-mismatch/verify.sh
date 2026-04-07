#!/bin/bash
# Checks the webhook receiver and Kafka for a config-mismatch alert.
#
# Usage: ./verify.sh [env|endpoints|args]   (default: env)
#
# The mismatch type determines which alert details are validated:
#   env       mismatchType=env,       mismatchedEnvVars contains MINIO_SITE_NAME
#   endpoints mismatchType=endpoints, expectedEndpointsCount and actualEndpointsCount present
#   args      mismatchType=args,      expectedArgs and actualArgs present
set -euo pipefail

MISMATCH_TYPE="${1:-env}"

case "$MISMATCH_TYPE" in
  env|endpoints|args) ;;
  *)
    echo "Error: unknown mismatch type '$MISMATCH_TYPE'."
    echo "Usage: $0 [env|endpoints|args]"
    exit 1
    ;;
esac

PASS=0
FAIL=0
ALERT_TYPE="config-mismatch"
MAX_WAIT_SECONDS=180   # 3 minutes; alert fires at startup, should be fast
POLL_INTERVAL=10

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Bootstrap Config Mismatch Alert - Verification ==="
echo "  Expected alert type:    $ALERT_TYPE"
echo "  Expected mismatch type: $MISMATCH_TYPE"
echo "  Expected peer:          minio4"
echo "  Waiting up to $((MAX_WAIT_SECONDS / 60)) minutes..."
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
    pass "config-mismatch alert received via webhook ($ALERT_COUNT alert(s))"
else
    fail "No config-mismatch alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

# --- Check Kafka ---
echo "--- Kafka topic ---"
KAFKA_COUNT=$(
    docker exec kafka-mismatch kafka-console-consumer \
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
    pass "config-mismatch alert found in Kafka ($KAFKA_COUNT message(s))"
else
    fail "No config-mismatch alert found in Kafka alert-events topic"
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

# --- Extract alert fields ---
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
            d.get('peerAddress', ''),
            d.get('mismatchType', ''),
            d.get('mismatchedEnvVars', ''),
            d.get('expectedEndpointsCount', ''),
            d.get('actualEndpointsCount', ''),
            d.get('expectedArgs', ''),
            d.get('actualArgs', ''),
            a.get('dedupKey', ''),
        ]
        print('|'.join(fields))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$DETAIL" ]; then
    TITLE=$(echo "$DETAIL"         | cut -d'|' -f1)
    PEER_ADDR=$(echo "$DETAIL"     | cut -d'|' -f2)
    MISMATCH_T=$(echo "$DETAIL"    | cut -d'|' -f3)
    MISMATCHED=$(echo "$DETAIL"    | cut -d'|' -f4)
    EXP_EP=$(echo "$DETAIL"        | cut -d'|' -f5)
    ACT_EP=$(echo "$DETAIL"        | cut -d'|' -f6)
    EXP_ARGS=$(echo "$DETAIL"      | cut -d'|' -f7)
    ACT_ARGS=$(echo "$DETAIL"      | cut -d'|' -f8)
    DEDUP=$(echo "$DETAIL"         | cut -d'|' -f9)

    echo "$TITLE" | grep -q "Server Configuration Mismatch" \
        && pass "Alert title correct: '$TITLE'" \
        || fail "Unexpected alert title: '$TITLE'"

    echo "$PEER_ADDR" | grep -q "minio4" \
        && pass "peerAddress identifies minio4: '$PEER_ADDR'" \
        || fail "peerAddress does not reference minio4: '$PEER_ADDR'"

    # Type-specific field checks
    case "$MISMATCH_TYPE" in
      env)
        [ "$MISMATCH_T" = "env" ] \
            && pass "mismatchType=env" \
            || fail "Expected mismatchType=env, got '$MISMATCH_T'"
        echo "$MISMATCHED" | grep -q "MINIO_SITE_NAME" \
            && pass "mismatchedEnvVars contains MINIO_SITE_NAME: '$MISMATCHED'" \
            || fail "mismatchedEnvVars missing MINIO_SITE_NAME: '$MISMATCHED'"
        ;;

      endpoints)
        [ "$MISMATCH_T" = "endpoints" ] \
            && pass "mismatchType=endpoints" \
            || fail "Expected mismatchType=endpoints, got '$MISMATCH_T'"
        [ -n "$EXP_EP" ] && [ -n "$ACT_EP" ] \
            && pass "endpoint counts present: expected=$EXP_EP actual=$ACT_EP" \
            || fail "endpoint counts missing (expected='$EXP_EP' actual='$ACT_EP')"
        [ "$EXP_EP" != "$ACT_EP" ] \
            && pass "endpoint counts differ ($EXP_EP vs $ACT_EP)" \
            || fail "endpoint counts are equal — mismatch not detected"
        ;;

      args)
        [ "$MISMATCH_T" = "args" ] \
            && pass "mismatchType=args" \
            || fail "Expected mismatchType=args, got '$MISMATCH_T'"
        [ -n "$EXP_ARGS" ] && [ -n "$ACT_ARGS" ] \
            && pass "args present: expected='$EXP_ARGS' actual='$ACT_ARGS'" \
            || fail "args fields missing (expected='$EXP_ARGS' actual='$ACT_ARGS')"
        [ "$EXP_ARGS" != "$ACT_ARGS" ] \
            && pass "CmdLine args differ" \
            || fail "CmdLine args are equal — mismatch not detected"
        ;;
    esac

    echo "$DEDUP" | grep -q "config-mismatch" \
        && pass "dedupKey references config-mismatch: '$DEDUP'" \
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
