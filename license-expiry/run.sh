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

# MINIO_LICENSE_EXPIRED must be a license whose ExpiresAt is in the past but
# whose grace period has not yet ended — i.e. the server is in grace-period
# state and will start normally while emitting a license-expiry alert.
if [ -z "${MINIO_LICENSE_EXPIRED:-}" ]; then
    echo "Error: MINIO_LICENSE_EXPIRED is not set."
    echo ""
    echo "  This scenario requires a license whose ExpiresAt has passed but"
    echo "  whose grace period is still active. Set it in .env:"
    echo ""
    echo "    MINIO_LICENSE_EXPIRED=<expired-but-in-grace-period license token>"
    echo ""
    echo "  If you only have a valid (non-expired) license the cluster will"
    echo "  start but no license-expiry alert will fire."
    exit 1
fi

# Write local .env so docker compose picks up the expired license as
# MINIO_LICENSE (the variable name the server reads).
cat > "$SCRIPT_DIR/.env" <<EOF
MINIO_IMAGE=${MINIO_IMAGE}
MINIO_LICENSE=${MINIO_LICENSE_EXPIRED}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
_MINIO_SUBNET_URL=${_MINIO_SUBNET_URL:-}
MINIO_CALLHOME_ENABLE=${MINIO_CALLHOME_ENABLE:-off}
EOF

echo "Using MinIO image: $MINIO_IMAGE"
echo "Starting services..."
cd "$SCRIPT_DIR"
# Unset MINIO_LICENSE from the shell environment so Docker Compose reads it
# from the local .env file (which holds the expired license). Shell env vars
# take precedence over .env files, so without this unset the parent .env's
# valid license would be injected into the containers instead.
unset MINIO_LICENSE
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

echo -n "  MinIO: "
for i in $(seq 1 90); do
    if curl -sf http://localhost:9010/minio/health/live > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 90 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 2
done

echo ""
echo "=== All services running ==="
echo ""
echo "  MinIO API:     http://localhost:9010"
echo "  MinIO Console: http://localhost:9011  (minioadmin / minioadmin)"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "The license-expiry alert fires on the first monitor check after startup."
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for the license-expiry alert (waits up to 5 min)"
echo "  docker compose logs minio1-license  # View MinIO logs"
echo "  docker compose down                 # Stop and clean up"
