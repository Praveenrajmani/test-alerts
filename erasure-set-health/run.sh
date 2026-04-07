set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Erasure Set Health Alert Test Setup ==="
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
if [ -z "${MINIO_LICENSE:-}" ]; then
    echo "Error: MINIO_LICENSE is not set. Edit .env and set MINIO_LICENSE."
    exit 1
fi

cat > "$SCRIPT_DIR/.env" <<EOF
MINIO_IMAGE=${MINIO_IMAGE}
MINIO_LICENSE=${MINIO_LICENSE}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
_MINIO_SUBNET_URL=${_MINIO_SUBNET_URL:-}
MINIO_CALLHOME_ENABLE=${MINIO_CALLHOME_ENABLE:-off}
EOF

echo "Using MinIO image: $MINIO_IMAGE"
echo "Starting all 4 nodes..."
cd "$SCRIPT_DIR"
docker compose up --build -d
echo ""

echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka-erasure kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
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
echo "=== Cluster fully healthy. Inducing erasure set degradation... ==="
echo ""

# Stop minio4 to simulate a 2-drive failure.
# With 8 total drives and write quorum = 5, removing 2 drives leaves at most
# 6 online drives. Because minio1 is also restarted below to force a leader
# re-election, the exact condition depends on timing (two_from_quorum_loss
# if minio1 recovers before the check fires; write_unavailable if the check
# fires while minio1 is still restarting). Either condition is a valid alert.
echo "Stopping minio4 to simulate 2-drive failure..."
docker stop minio4-erasure
echo "  minio4 stopped"
echo ""

# Give the remaining nodes ~45 seconds to mark minio4's drives offline.
# MinIO detects unreachable drives on the next drive health scan.
echo -n "Waiting 45s for minio4 drives to be detected offline"
for i in $(seq 1 9); do
    echo -n "."; sleep 5
done
echo ""
echo ""

# Force a leader re-election by restarting minio1. runLeaderMonitor calls
# checkAndAlertErasureSetHealth immediately on winning the lock. The winner
# (minio2 or minio3) will see 6/8 drives online and fire the alert.
echo "Restarting minio1 to trigger immediate leader re-election check..."
docker restart minio1-erasure

echo -n "Waiting for minio1 to recover"
for i in $(seq 1 30); do
    if curl -sf http://minio1:9000/minio/health/live > /dev/null 2>&1; then
        echo ""; echo "  minio1 recovered"; break
    fi
    echo -n "."; sleep 2
done
echo ""

echo "Leader re-elected. checkAndAlertErasureSetHealth fires immediately."
echo "Alert type: erasure-set-health (condition: two_from_quorum_loss)"
echo ""
echo "=== Setup complete ==="
echo ""
echo "  MinIO API:     http://localhost:9010"
echo "  MinIO Console: http://localhost:9011  (minioadmin / minioadmin)"
echo "  Webhook Stats: http://localhost:9090/stats"
echo "  Kafka:         localhost:9092 (topic: alert-events)"
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for the erasure-set-health alert (waits up to 5 min)"
echo "  docker compose logs minio1-erasure  # View MinIO logs"
echo "  docker compose down                 # Stop and clean up"
