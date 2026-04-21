set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== License Expiry Alert Test Setup ==="
echo ""

for env_file in "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env"; do
    if [ -f "$env_file" ]; then
        set -a; source "$env_file"; set +a
    fi
done

if [ -z "${MINIO_IMAGE:-}" ]; then
    echo "Error: MINIO_IMAGE is not set. Edit .env and set MINIO_IMAGE."
    exit 1
fi
if [ -z "${MINIO_EXPIRED_LICENSE:-}" ]; then
    echo "Error: MINIO_EXPIRED_LICENSE is not set."
    echo ""
    echo "  This scenario requires a fully-expired MinIO AIStor license."
    echo "  Set MINIO_EXPIRED_LICENSE in .env to the contents of an expired"
    echo "  commercial or trial license (not a free/community license, which"
    echo "  has no expiry and will not trigger the alert)."
    exit 1
fi

cat > "$SCRIPT_DIR/.env" <<EOF
MINIO_IMAGE=${MINIO_IMAGE}
MINIO_EXPIRED_LICENSE=${MINIO_EXPIRED_LICENSE}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
_MINIO_SUBNET_URL=${_MINIO_SUBNET_URL:-}
MINIO_CALLHOME_ENABLE=${MINIO_CALLHOME_ENABLE:-off}
EOF

echo "Using MinIO image: $MINIO_IMAGE"
echo "Starting 4-node cluster with expired license..."
cd "$SCRIPT_DIR"
docker compose up --build -d
echo ""

echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka-license kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
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

echo -n "  MinIO (all 4 nodes): "
for i in $(seq 1 90); do
    if curl -sf http://localhost:9010/minio/health/live > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 90 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 2
done

echo ""
echo "=== Cluster running with expired license ==="
echo ""
echo "  The licenseExpiryMonitor fires immediately when the leader is elected"
echo "  (runLeaderMonitor calls Check() before the first 24-hour tick)."
echo "  Alert type: license-expiry  state: fully_expired"
echo ""
echo "  MinIO API:     http://localhost:9010"
echo "  MinIO Console: http://localhost:9011  (minioadmin / minioadmin)"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for the license-expiry alert (waits up to 5 min)"
echo "  docker compose logs minio1-license  # View MinIO logs"
echo "  docker compose down                 # Stop and clean up"
