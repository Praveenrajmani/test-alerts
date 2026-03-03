#!/bin/bash
set -e

MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://localhost:9010}"

echo "=== MinIO Alert Targets - Alert Generator ==="
echo "  Endpoint: $MINIO_ENDPOINT"
echo ""

echo "Triggering test alerts..."
RESP=$(curl -sfk "$MINIO_ENDPOINT/minio/health/test-alerts" 2>&1) || true
if [ -n "$RESP" ]; then
    echo "  $RESP"
else
    echo "  (no response - is MinIO running?)"
fi

echo ""
echo "Run ./verify.sh to check that alerts were received."
