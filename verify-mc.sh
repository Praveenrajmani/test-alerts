# verify-mc.sh — sourced by every verify.sh to add an `mc alerts` check.
#
# Requires MC_IMAGE to be set in .env.  When unset, the check is silently
# skipped so existing workflows are unaffected.
#
# Callers must define pass() and fail() before sourcing this file.
#
# Usage:
#   check_mc_alerts <alert_type> [endpoint] [extra_mc_flags...]
#
#   alert_type     — e.g. "storage-capacity", "kms-unavailable"
#   endpoint       — defaults to http://localhost:9010
#   extra_mc_flags — optional; pass "--insecure" for self-signed TLS

check_mc_alerts() {
    local alert_type="$1"
    local endpoint="${2:-http://localhost:9010}"
    shift 2 2>/dev/null || true
    local extra_flags="${*:-}"   # e.g. "--insecure"

    echo "--- mc alerts ---"

    # MC_IMAGE may not be exported; source .env files relative to the calling
    # script (BASH_SOURCE[1] is the verify.sh that sourced this file).
    local caller_dir
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    for _f in "$caller_dir/../.env" "$caller_dir/.env"; do
        [ -f "$_f" ] && { set -a; source "$_f"; set +a; } 2>/dev/null || true
    done

    if [ -z "${MC_IMAGE:-}" ]; then
        echo "  (skipped: MC_IMAGE not set)"
        return 0
    fi

    local user="${MINIO_ROOT_USER:-minioadmin}"
    local pass_val="${MINIO_ROOT_PASSWORD:-minioadmin}"

    # Build MC_HOST_<alias> URL: scheme://user:password@host:port
    local scheme host_part mc_host_url
    scheme="${endpoint%%://*}"
    host_part="${endpoint#*://}"
    mc_host_url="${scheme}://${user}:${pass_val}@${host_part}"

    local mc_output
    mc_output=$(docker run --rm --network host \
        -e "MC_HOST_test=${mc_host_url}" \
        "$MC_IMAGE" $extra_flags alerts --types "$alert_type" test --json 2>/dev/null) || true

    if [ -z "$mc_output" ]; then
        fail "mc alerts: no output (MC_IMAGE=$MC_IMAGE, endpoint=$endpoint)"
        return 0
    fi

    local alert_count
    alert_count=$(echo "$mc_output" | python3 -c "
import sys, json
count = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if d.get('type') == '$alert_type':
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0")

    if [ "${alert_count:-0}" -gt 0 ]; then
        pass "mc alerts: $alert_type found ($alert_count alert(s))"
        echo "  Last mc alert entry:"
        echo "$mc_output" | python3 -c "
import sys, json
alerts = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if d.get('type') == '$alert_type':
            alerts.append(d)
    except Exception:
        pass
if alerts:
    print(json.dumps(alerts[-1], indent=2))
" 2>/dev/null | sed 's/^/    /' || true
    else
        fail "mc alerts: no $alert_type alert found"
        echo "  mc output (first 3 lines):"
        echo "$mc_output" | head -3 | sed 's/^/    /'
    fi
}
