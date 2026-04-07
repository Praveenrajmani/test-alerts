#!/bin/bash
# Polls for scanner-excess-folders and scanner-excess-versions alerts in the
# webhook receiver and Kafka. The alerts fire after the scanner detects excess
# conditions and the 2-minute monitor interval elapses.
# This script waits up to 10 minutes for both alerts to arrive.
set -euo pipefail

PASS=0
FAIL=0
MAX_WAIT_SECONDS=1500  # 25 minutes
POLL_INTERVAL=15

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Scanner Excess Alerts - Verification ==="
echo "  Waiting up to $((MAX_WAIT_SECONDS / 60)) minutes for scanner-excess-folders and scanner-excess-versions."
echo "  (Scanner startup varies by Docker cache state; ~2-5 min warm, ~20 min cold.)"
echo ""

# ── Poll webhook for scanner-excess-folders ───────────────────────────────────
echo "--- Polling webhook for scanner-excess-folders ---"
FOUND_FOLDERS=false
ELAPSED=0
while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
    FOLDER_COUNT=$(
        curl -sf "http://localhost:9090/entries" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    count = sum(1 for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-folders')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0"
    )
    if [ "${FOLDER_COUNT:-0}" -gt 0 ]; then
        FOUND_FOLDERS=true
        break
    fi
    echo -n "."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
echo ""

if $FOUND_FOLDERS; then
    pass "scanner-excess-folders alert received via webhook ($FOLDER_COUNT alert(s))"
else
    fail "No scanner-excess-folders alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

# ── Poll webhook for scanner-excess-versions ──────────────────────────────────
echo "--- Polling webhook for scanner-excess-versions ---"
FOUND_VERSIONS=false
ELAPSED=0
while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
    VERSION_COUNT=$(
        curl -sf "http://localhost:9090/entries" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    count = sum(1 for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-versions')
    print(count)
except Exception:
    print(0)
" 2>/dev/null || echo "0"
    )
    if [ "${VERSION_COUNT:-0}" -gt 0 ]; then
        FOUND_VERSIONS=true
        break
    fi
    echo -n "."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
echo ""

if $FOUND_VERSIONS; then
    pass "scanner-excess-versions alert received via webhook ($VERSION_COUNT alert(s))"
else
    fail "No scanner-excess-versions alert received via webhook after $((MAX_WAIT_SECONDS / 60)) minutes"
fi

echo ""

# ── Check Kafka for scanner-excess-folders ────────────────────────────────────
echo "--- Kafka: scanner-excess-folders ---"
KAFKA_FOLDERS=$(
    docker exec kafka-scanner kafka-console-consumer \
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
        if d.get('type') == 'scanner-excess-folders':
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0"
)

if [ "${KAFKA_FOLDERS:-0}" -gt 0 ]; then
    pass "scanner-excess-folders alert found in Kafka ($KAFKA_FOLDERS message(s))"
else
    fail "No scanner-excess-folders alert found in Kafka alert-events topic"
fi

echo ""

# ── Check Kafka for scanner-excess-versions ───────────────────────────────────
echo "--- Kafka: scanner-excess-versions ---"
KAFKA_VERSIONS=$(
    docker exec kafka-scanner kafka-console-consumer \
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
        if d.get('type') == 'scanner-excess-versions':
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0"
)

if [ "${KAFKA_VERSIONS:-0}" -gt 0 ]; then
    pass "scanner-excess-versions alert found in Kafka ($KAFKA_VERSIONS message(s))"
else
    fail "No scanner-excess-versions alert found in Kafka alert-events topic"
fi

echo ""

# ── Show alert detail (from webhook) ─────────────────────────────────────────
echo "--- Alert detail: scanner-excess-folders ---"
curl -sf "http://localhost:9090/entries" 2>/dev/null \
| python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-folders']
    if alerts:
        print(json.dumps(alerts[-1], indent=2))
    else:
        print('  (none)')
except Exception as e:
    print('  (unavailable: ' + str(e) + ')')
" 2>/dev/null || echo "  (unavailable)"

echo ""
echo "--- Alert detail: scanner-excess-versions ---"
curl -sf "http://localhost:9090/entries" 2>/dev/null \
| python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-versions']
    if alerts:
        print(json.dumps(alerts[-1], indent=2))
    else:
        print('  (none)')
except Exception as e:
    print('  (unavailable: ' + str(e) + ')')
" 2>/dev/null || echo "  (unavailable)"

echo ""

# ── Verify scanner-excess-folders content ─────────────────────────────────────
echo "--- Checking scanner-excess-folders content ---"
FOLDER_DETAIL=$(
    curl -sf "http://localhost:9090/entries" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-folders']
    if alerts:
        a = alerts[-1]
        details = a.get('details', {})
        title = a.get('title', '')
        dedup = a.get('dedupKey', '')
        detections = details.get('detections', '')
        threshold = details.get('threshold', '')
        paths = details.get('paths', '')
        print(title + '|' + dedup + '|' + detections + '|' + threshold + '|' + paths)
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$FOLDER_DETAIL" ]; then
    F_TITLE=$(echo "$FOLDER_DETAIL" | cut -d'|' -f1)
    F_DEDUP=$(echo "$FOLDER_DETAIL" | cut -d'|' -f2)
    F_DETECTIONS=$(echo "$FOLDER_DETAIL" | cut -d'|' -f3)
    F_THRESHOLD=$(echo "$FOLDER_DETAIL" | cut -d'|' -f4)
    F_PATHS=$(echo "$FOLDER_DETAIL" | cut -d'|' -f5)

    [ "$F_TITLE" = "Scanner: Prefixes with excessive sub-folders detected" ] \
        && pass "Folders alert title correct" \
        || fail "Unexpected folders alert title: '$F_TITLE'"

    echo "$F_DEDUP" | grep -qE '^scanner-excess-folders-[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        && pass "Folders dedupKey format correct: '$F_DEDUP'" \
        || fail "Unexpected folders dedupKey format: '$F_DEDUP'"

    [ -n "$F_DETECTIONS" ] && [ "$F_DETECTIONS" != "0" ] \
        && pass "Folders detections=$F_DETECTIONS (non-zero)" \
        || fail "Folders detections is zero or missing"

    [ "$F_THRESHOLD" = "3" ] \
        && pass "Folders threshold=3 as configured" \
        || fail "Unexpected folders threshold: '$F_THRESHOLD'"

    echo "$F_PATHS" | grep -q "parent" \
        && pass "Folders paths contains 'parent' prefix" \
        || fail "Folders paths missing expected 'parent' prefix: '$F_PATHS'"
else
    fail "Could not parse scanner-excess-folders alert details"
fi

echo ""

# ── Verify scanner-excess-versions content ────────────────────────────────────
echo "--- Checking scanner-excess-versions content ---"
VERSION_DETAIL=$(
    curl -sf "http://localhost:9090/entries" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    entries = json.load(sys.stdin)
    alerts = [e for e in entries if isinstance(e, dict) and e.get('type') == 'scanner-excess-versions']
    if alerts:
        a = alerts[-1]
        details = a.get('details', {})
        title = a.get('title', '')
        dedup = a.get('dedupKey', '')
        detections = details.get('detections', '')
        version_threshold = details.get('version_threshold', '')
        objects = details.get('objects', '')
        print(title + '|' + dedup + '|' + detections + '|' + version_threshold + '|' + objects)
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
)

if [ -n "$VERSION_DETAIL" ]; then
    V_TITLE=$(echo "$VERSION_DETAIL" | cut -d'|' -f1)
    V_DEDUP=$(echo "$VERSION_DETAIL" | cut -d'|' -f2)
    V_DETECTIONS=$(echo "$VERSION_DETAIL" | cut -d'|' -f3)
    V_THRESHOLD=$(echo "$VERSION_DETAIL" | cut -d'|' -f4)
    V_OBJECTS=$(echo "$VERSION_DETAIL" | cut -d'|' -f5)

    [ "$V_TITLE" = "Scanner: Objects with excessive versions detected" ] \
        && pass "Versions alert title correct" \
        || fail "Unexpected versions alert title: '$V_TITLE'"

    echo "$V_DEDUP" | grep -qE '^scanner-excess-versions-[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        && pass "Versions dedupKey format correct: '$V_DEDUP'" \
        || fail "Unexpected versions dedupKey format: '$V_DEDUP'"

    [ -n "$V_DETECTIONS" ] && [ "$V_DETECTIONS" != "0" ] \
        && pass "Versions detections=$V_DETECTIONS (non-zero)" \
        || fail "Versions detections is zero or missing"

    [ "$V_THRESHOLD" = "3" ] \
        && pass "Versions threshold=3 as configured" \
        || fail "Unexpected versions threshold: '$V_THRESHOLD'"

    echo "$V_OBJECTS" | grep -q "versioned-obj" \
        && pass "Versions objects contains 'versioned-obj'" \
        || fail "Versions objects missing expected 'versioned-obj': '$V_OBJECTS'"
else
    fail "Could not parse scanner-excess-versions alert details"
fi

echo ""

# shellcheck source=../verify-mc.sh
source "$(dirname "$0")/../verify-mc.sh"
check_mc_alerts "scanner-excess-folders" "http://localhost:9010"

echo ""

# shellcheck source=../verify-mc.sh
source "$(dirname "$0")/../verify-mc.sh"
check_mc_alerts "scanner-excess-versions" "http://localhost:9010"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
