#!/bin/bash
# Sets up the scanner excess alert test:
#   1. Starts the 4-node MinIO cluster with Kafka and webhook receiver.
#   2. Creates test data via mc (docker run --rm):
#       - 4 sub-folders under test-scanner/parent/  (threshold=3 → excess folders alert)
#       - 4 versions of test-scanner/versioned-obj  (threshold=3 → excess versions alert)
#   3. The scanner detects excess conditions and populates metrics.
#   4. The alert monitor fires every 2m (_MINIO_SCANNER_EXCESS_ALERT_INTERVAL).
#
# Run ./verify.sh after this to confirm both alerts reached Kafka and webhook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Scanner Excess Alert Test Setup ==="
echo ""

# --- Validate environment ---
for env_file in "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env"; do
    if [ -f "$env_file" ]; then
        set -a; source "$env_file"; set +a
    fi
done

if [ -z "${MINIO_IMAGE:-}" ]; then
    echo "Error: MINIO_IMAGE is not set. Edit .env and set MINIO_IMAGE."
    exit 1
fi
if [ -z "${MINIO_LICENSE:-}" ]; then
    echo "Error: MINIO_LICENSE is not set. Edit .env and set MINIO_LICENSE."
    exit 1
fi

MC_IMAGE="${MC_IMAGE:-docker.io/praveenminio/mc:new-alerts}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"

# Write a local .env so plain `docker compose down|logs|ps` works from
# this directory without sourcing the parent .env manually each time.
cat > "$SCRIPT_DIR/.env" <<EOF
MINIO_IMAGE=${MINIO_IMAGE}
MINIO_LICENSE=${MINIO_LICENSE}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MC_IMAGE=${MC_IMAGE}
_MINIO_SUBNET_URL=${_MINIO_SUBNET_URL:-}
MINIO_CALLHOME_ENABLE=${MINIO_CALLHOME_ENABLE:-off}
EOF

# --- Start services ---
echo "Using MinIO image: $MINIO_IMAGE"
echo "Using mc image:    $MC_IMAGE"
echo ""
echo "Scanner thresholds: MINIO_SCANNER_ALERT_EXCESS_FOLDERS=3, MINIO_SCANNER_ALERT_EXCESS_VERSIONS=3"
echo "Alert interval:     _MINIO_SCANNER_EXCESS_ALERT_INTERVAL=1m"
echo ""
echo "Starting services..."
cd "$SCRIPT_DIR"
docker compose up --build -d
echo ""

# --- Wait for health ---
echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka-scanner kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
        echo "ready"; break
    fi
    [ "$i" -eq 60 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 2
done

echo -n "  Webhook: "
for i in $(seq 1 30); do
    if curl -sf http://localhost:9090/health > /dev/null 2>&1; then
        echo "ready"; break
    fi
    [ "$i" -eq 30 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 1
done

echo -n "  MinIO cluster: "
for i in $(seq 1 120); do
    if curl -sf http://localhost:9010/minio/health/live > /dev/null 2>&1; then
        echo "ready"; break
    fi
    [ "$i" -eq 120 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 3
done

# --- Create test data via mc ---
# The mc image is a scratch image (no shell), so run each command individually.
# MC_HOST_minio is set via the environment variable so no explicit alias setup needed.
echo ""
echo "Creating test data via mc..."

MC_HOST_URL="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:9010"

mc_run() {
    docker run --rm --network host \
        -e "MC_HOST_minio=${MC_HOST_URL}" \
        "$MC_IMAGE" "$@"
}

# mc_put creates an empty object at the given path by piping empty content via mc pipe.
mc_put() {
    echo "" | docker run -i --rm --network host \
        -e "MC_HOST_minio=${MC_HOST_URL}" \
        "$MC_IMAGE" pipe "$1"
}

# Create bucket with versioning enabled.
mc_run mb minio/test-scanner
mc_run version enable minio/test-scanner

# Create 4 sub-folders under parent/ (threshold=3, so 4 triggers excess folders alert).
mc_put minio/test-scanner/parent/sub1/placeholder
mc_put minio/test-scanner/parent/sub2/placeholder
mc_put minio/test-scanner/parent/sub3/placeholder
mc_put minio/test-scanner/parent/sub4/placeholder

# Put the same object 4 times to create 4 versions (threshold=3 → excess versions alert).
mc_put minio/test-scanner/versioned-obj
mc_put minio/test-scanner/versioned-obj
mc_put minio/test-scanner/versioned-obj
mc_put minio/test-scanner/versioned-obj

echo "  Test data created."

echo ""
echo "=== All services running ==="
echo ""
echo "  MinIO API:     http://localhost:9010"
echo "  MinIO Console: http://localhost:9011  (${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD})"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "Test data: 4 sub-folders under test-scanner/parent/, 4 versions of test-scanner/versioned-obj."
echo "The scanner will detect excess conditions; the alert monitor fires every 2m."
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for scanner excess alerts (waits up to 10 min)"
echo "  docker compose logs minio1-scanner  # View MinIO logs"
echo "  docker compose down                 # Stop and clean up"
