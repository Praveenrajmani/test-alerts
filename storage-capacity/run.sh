#!/bin/bash
# Sets up the storage capacity alert test:
#   1. Starts the 4-node MinIO cluster with 500MB tmpfs drives per node
#   2. Each node's entrypoint (fill-and-start.sh) pre-fills drives to 93%
#      before MinIO starts, so usable free space is ~7% (below 10% threshold)
#   3. The storage-capacity alert fires on the first monitor run, which happens
#      immediately after the leader node is elected (within ~1-2 minutes)
#
# Run ./verify.sh after this to confirm the alert reached Kafka and webhook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Storage Capacity Alert Test Setup ==="
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

# Write a local .env so plain `docker compose down|logs|ps` works from
# this directory without sourcing the parent .env manually each time.
cat > "$SCRIPT_DIR/.env" <<EOF
MINIO_IMAGE=${MINIO_IMAGE}
MINIO_LICENSE=${MINIO_LICENSE}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
_MINIO_SUBNET_URL=${_MINIO_SUBNET_URL:-}
MINIO_CALLHOME_ENABLE=${MINIO_CALLHOME_ENABLE:-off}
EOF

# --- Start services ---
echo "Using MinIO image: $MINIO_IMAGE"
echo ""
echo "Each MinIO node uses 2x 50MB tmpfs drives. The fill-and-start.sh"
echo "entrypoint fills each drive to 93% before MinIO starts (~3.5MB free)."
echo ""
echo "Starting services..."
cd "$SCRIPT_DIR"
docker compose up --build -d
echo ""

# --- Wait for health ---
echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka-storage kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 60 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 2
done

echo -n "  Webhook: "
for i in $(seq 1 30); do
    if curl -sf http://localhost:9090/health > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 30 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 1
done

# fill-and-start.sh pre-fills ~46MB per drive (50MB tmpfs at 93%), which
# completes in under a second. Most of the wait below is cluster init time.
echo -n "  MinIO (pre-filling drives + cluster init): "
for i in $(seq 1 120); do
    if curl -sf http://localhost:9010/minio/health/live > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 120 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 3
done

echo ""
echo "=== All services running ==="
echo ""
echo "  MinIO API:     http://localhost:9010"
echo "  MinIO Console: http://localhost:9011  (minioadmin / minioadmin)"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "Storage drives are pre-filled to 93%. The storage-capacity alert fires"
echo "on the first monitor run immediately after leader election (~1-2 minutes)."
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for the storage-capacity alert (waits up to 5 min)"
echo "  docker compose logs minio1-storage  # View MinIO logs"
echo "  docker compose down                 # Stop and clean up"
