#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCENARIOS=(
    "$SCRIPT_DIR"
    "$SCRIPT_DIR/kms-unavailability"
    "$SCRIPT_DIR/storage-capacity"
    "$SCRIPT_DIR/bootstrap-mismatch"
    "$SCRIPT_DIR/erasure-set-health"
    "$SCRIPT_DIR/scanner-excess"
    "$SCRIPT_DIR/license-expiry"
)

echo "================================================"
echo " MinIO AIStor Alert Scenarios — Teardown"
echo "================================================"

for dir in "${SCENARIOS[@]}"; do
    if [ -f "$dir/docker-compose.yaml" ]; then
        echo "Tearing down: $dir"
        docker compose -f "$dir/docker-compose.yaml" down --volumes --remove-orphans 2>/dev/null || true
    fi
done

echo ""
echo "All scenarios torn down."
