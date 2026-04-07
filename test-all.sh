#!/usr/bin/env bash
# test-all.sh — run every alert scenario end-to-end using the new-alerts image.
#
# Scenarios executed:
#   1. TLS certificate expiry      (root)               — certificate-expiry
#   2. KMS unavailability          (kms-unavailability/) — kms-unavailable
#   3. Storage capacity critical   (storage-capacity/)   — storage-capacity
#   4. Bootstrap config mismatch   (bootstrap-mismatch/) — config-mismatch (env, endpoints, args)
#   5. Erasure set health          (erasure-set-health/) — erasure-set-health
#   6. Scanner excess              (scanner-excess/)     — scanner-excess-folders, scanner-excess-versions
#
# Each scenario is run in isolation: `docker compose down` is called before
# and after each run to guarantee clean state.
#
# Usage:
#   ./test-all.sh                  # run all scenarios
#   ./test-all.sh cert             # run only TLS cert expiry
#   ./test-all.sh kms              # run only KMS unavailability
#   ./test-all.sh storage          # run only storage capacity
#   ./test-all.sh mismatch         # run only bootstrap mismatch (all 3 sub-types)
#   ./test-all.sh erasure          # run only erasure set health
#   ./test-all.sh scanner          # run only scanner excess
#
# Prerequisites: Docker, docker compose v2, curl, python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-all}"

# ── colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; }
err()  { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ── result tracking ───────────────────────────────────────────────────────────
PASSED=()
FAILED=()

record_pass() { PASSED+=("$1"); }
record_fail() { FAILED+=("$1"); }

# ── load .env ─────────────────────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

if [ -z "${MINIO_IMAGE:-}" ]; then
    echo "Error: MINIO_IMAGE is not set. Edit .env and set MINIO_IMAGE."
    exit 1
fi
if [ -z "${MINIO_LICENSE:-}" ]; then
    echo "Error: MINIO_LICENSE is not set. Edit .env and set MINIO_LICENSE."
    exit 1
fi

echo "================================================"
echo " MinIO AIStor Alert Scenarios — End-to-End Test"
echo "================================================"
echo " Image:  $MINIO_IMAGE"
echo " Date:   $(date)"
echo "================================================"
echo ""

# ── helper: run a scenario ────────────────────────────────────────────────────
# run_scenario <label> <dir> <run_args> <verify_args>
run_scenario() {
    local label="$1"
    local dir="$2"
    local run_args="${3:-}"
    local verify_args="${4:-}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Scenario: $label"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # clean slate
    cd "$dir"
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    echo ""

    # run
    if bash run.sh $run_args; then
        echo ""
        # verify
        if bash verify.sh $verify_args; then
            ok "$label — PASSED"
            record_pass "$label"
        else
            err "$label — FAILED (verify.sh returned non-zero)"
            record_fail "$label"
        fi
    else
        err "$label — FAILED (run.sh returned non-zero)"
        record_fail "$label"
    fi

    echo ""
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    cd "$SCRIPT_DIR"
}

# ── scenario 1: TLS certificate expiry ───────────────────────────────────────
run_cert() {
    local mode="${1:-expiring}"
    local label="TLS Certificate Expiry ($mode)"
    local dir="$SCRIPT_DIR"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Scenario: $label"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cd "$dir"
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    echo ""

    if bash run.sh "$mode"; then
        echo ""
        if bash verify.sh; then
            ok "$label — PASSED"
            record_pass "$label"
        else
            err "$label — FAILED (verify.sh returned non-zero)"
            record_fail "$label"
        fi
    else
        err "$label — FAILED (run.sh returned non-zero)"
        record_fail "$label"
    fi

    echo ""
    docker compose down --volumes --remove-orphans 2>/dev/null || true
    cd "$SCRIPT_DIR"
}

# ── scenario 4: bootstrap mismatch (three sub-types) ─────────────────────────
run_mismatch() {
    for mtype in env endpoints args; do
        run_scenario "Bootstrap Config Mismatch ($mtype)" \
            "$SCRIPT_DIR/bootstrap-mismatch" \
            "$mtype" \
            "$mtype"
    done
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$FILTER" in
    cert)
        run_cert expiring
        ;;
    kms)
        run_scenario "KMS Unavailability" "$SCRIPT_DIR/kms-unavailability"
        ;;
    storage)
        run_scenario "Storage Capacity Critical" "$SCRIPT_DIR/storage-capacity"
        ;;
    mismatch)
        run_mismatch
        ;;
    erasure)
        run_scenario "Erasure Set Health" "$SCRIPT_DIR/erasure-set-health"
        ;;
    scanner)
        run_scenario "Scanner Excess" "$SCRIPT_DIR/scanner-excess"
        ;;
    all)
        run_cert expiring
        run_scenario "KMS Unavailability"         "$SCRIPT_DIR/kms-unavailability"
        run_scenario "Storage Capacity Critical"  "$SCRIPT_DIR/storage-capacity"
        run_mismatch
        run_scenario "Erasure Set Health"         "$SCRIPT_DIR/erasure-set-health"
        run_scenario "Scanner Excess"             "$SCRIPT_DIR/scanner-excess"
        ;;
    *)
        echo "Usage: $0 [cert|kms|storage|mismatch|erasure|scanner|all]"
        exit 1
        ;;
esac

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " SUMMARY"
echo "================================================"

TOTAL_PASS=${#PASSED[@]}
TOTAL_FAIL=${#FAILED[@]}

for s in "${PASSED[@]}"; do
    ok "$s"
done
for s in "${FAILED[@]}"; do
    err "$s"
done

echo ""
echo "  Passed: $TOTAL_PASS"
echo "  Failed: $TOTAL_FAIL"
echo "  Total:  $((TOTAL_PASS + TOTAL_FAIL))"
echo "================================================"

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
