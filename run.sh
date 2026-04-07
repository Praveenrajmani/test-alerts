#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-expiring}"

echo "=== MinIO Alert Targets Test Setup ==="
echo ""

# --- Validate mode ---
case "$MODE" in
    expiring|expired|valid)
        ;;
    *)
        echo "Usage: $0 [expiring|expired|valid]"
        echo ""
        echo "  expiring  - cert expires in 3 days (triggers 'TLS Certificate Expiring' alert)"
        echo "  expired   - cert already expired (triggers 'TLS Certificate Expired' alert)"
        echo "  valid     - cert valid for 365 days (no cert alert, baseline test)"
        exit 1
        ;;
esac

# --- Check for .env ---
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env.sample" ]; then
        echo "No .env file found. Copying from .env.sample..."
        cp "$SCRIPT_DIR/.env.sample" "$SCRIPT_DIR/.env"
    fi
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

if [ -z "$MINIO_IMAGE" ]; then
    echo "Error: MINIO_IMAGE is not set."
    echo "Edit .env and set MINIO_IMAGE to your MinIO AIStor Docker image."
    exit 1
fi

if [ -z "$MINIO_LICENSE" ]; then
    echo "Error: MINIO_LICENSE is not set."
    echo ""
    echo "Options:"
    echo "  1. Edit .env and set MINIO_LICENSE"
    echo "  2. export MINIO_LICENSE=\$(cat /path/to/minio.license)"
    exit 1
fi

# --- Generate certificates ---
echo "Generating TLS certificates (mode: $MODE)..."
"$SCRIPT_DIR/generate-certs.sh" "$MODE"
echo ""

# --- Start services ---
echo "Using MinIO image: $MINIO_IMAGE"
echo "Starting services..."
cd "$SCRIPT_DIR"
docker compose up --build -d

# --- Wait for health ---
echo ""
echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    echo -n "."
    sleep 2
done

echo -n "  Webhook: "
for i in $(seq 1 30); do
    if curl -sf http://localhost:9090/health > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    echo -n "."
    sleep 1
done

echo -n "  MinIO: "
for i in $(seq 1 60); do
    if curl -sfk https://localhost:9010/minio/health/live > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    echo -n "."
    sleep 2
done

echo ""
echo "=== All services running (cert mode: $MODE) ==="
echo ""
echo "  MinIO API:     https://localhost:9010"
echo "  MinIO Console: https://localhost:9001  (minioadmin / minioadmin)"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "Next steps:"
echo "  ./verify.sh                 # Verify alerts received in Kafka + webhook"
echo "  docker compose logs minio1 minio2 minio3 minio4  # View MinIO logs"
echo "  docker compose logs webhook # View webhook receiver logs"
echo "  docker compose down         # Stop and clean up"
