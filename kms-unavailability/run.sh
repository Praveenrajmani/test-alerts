#!/bin/bash
# Sets up the KMS unavailability alert test:
#   1. Generates mTLS certificates for KES and MinIO
#   2. Writes KES server config with MinIO's identity
#   3. Starts all services (MinIO 4-node cluster + KES + Kafka + webhook)
#   4. Waits for the cluster to be fully healthy
#   5. Stops KES to simulate KMS unavailability
#
# The kms-unavailable alert fires within 5 minutes of KES going down.
# Run ./verify.sh to confirm the alert reached Kafka and the webhook receiver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== KMS Unavailability Alert Test Setup ==="
echo ""

# --- Validate environment ---
if [ ! -f "$SCRIPT_DIR/../.env" ] && [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/../.env.sample" ]; then
        echo "No .env file found. Copying from .env.sample..."
        cp "$SCRIPT_DIR/../.env.sample" "$SCRIPT_DIR/../.env"
    fi
fi

# Source .env from parent dir first, then local override
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

# --- Generate certificates ---
echo "Generating KES mTLS certificates..."
"$SCRIPT_DIR/generate-kes-certs.sh"
echo ""

ADMIN_IDENTITY=$(cat "$SCRIPT_DIR/certs/kes-admin-identity.txt")
KES_IDENTITY=$(cat "$SCRIPT_DIR/certs/minio-kes-identity.txt")

# --- Write KES server configuration ---
echo "Writing KES server config..."
echo "  admin identity:  $ADMIN_IDENTITY"
echo "  minio identity:  $KES_IDENTITY"
mkdir -p "$SCRIPT_DIR/config"
cat > "$SCRIPT_DIR/config/kes-config.yaml" <<EOF
version: v1
address: 0.0.0.0:7373

tls:
  key:  /certs/kes-server.key
  cert: /certs/kes-server.crt
  ca:   /certs/ca.crt

admin:
  # Dedicated admin identity — distinct from the MinIO policy identity.
  # KES rejects configs where the same identity appears in both admin and a policy.
  identity: ${ADMIN_IDENTITY}

policy:
  minio:
    allow:
      - /v1/key/create/*
      - /v1/key/generate/*
      - /v1/key/decrypt/*
      - /v1/key/bulk/decrypt
      - /v1/key/list/*
      - /v1/status
      - /v1/metrics
    identities:
      - ${KES_IDENTITY}

keystore:
  fs:
    path: /data   # keys are stored in the container's /data tmpfs
EOF
echo ""

# --- Start services ---
echo "Using MinIO image: $MINIO_IMAGE"
echo "Starting services..."
cd "$SCRIPT_DIR"
docker compose up --build -d
echo ""

# --- Wait for infrastructure ---
echo "Waiting for services to be ready..."

echo -n "  Kafka: "
for i in $(seq 1 60); do
    if docker exec kafka-kms kafka-broker-api-versions --bootstrap-server localhost:29092 > /dev/null 2>&1; then
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

# Wait for KES to accept mTLS connections before checking MinIO. This is
# critical: if the KMS monitor fires its first check before KES is ready,
# the dedup key "kms-unavailable" would be set prematurely and the real
# test alert (after we stop KES) would be suppressed for 24 hours.
# We use the MinIO client cert so the check tests real mTLS, not just TCP.
echo -n "  KES: "
for i in $(seq 1 30); do
    if curl -sf --connect-timeout 2 \
         --cacert "$SCRIPT_DIR/certs/ca.crt" \
         --cert   "$SCRIPT_DIR/certs/minio-kes-client.crt" \
         --key    "$SCRIPT_DIR/certs/minio-kes-client.key" \
         https://localhost:7373/v1/status > /dev/null 2>&1; then
        echo "ready"
        break
    fi
    [ "$i" -eq 30 ] && { echo "TIMEOUT"; exit 1; }
    echo -n "."; sleep 2
done

echo -n "  MinIO (4-node cluster with KES): "
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
echo "  KES:           https://localhost:7373 (running)"
echo ""

# --- Stop KES to simulate KMS unavailability ---
echo "Stopping KES to simulate KMS unavailability..."
docker stop kes-kms
# Confirm the container is actually stopped (not just "Exited" from a crash).
KES_STATE=$(docker inspect -f '{{.State.Status}}' kes-kms 2>/dev/null || echo "unknown")
echo "  KES container state: $KES_STATE"
if [ "$KES_STATE" != "exited" ]; then
    echo "Warning: KES container is not in 'exited' state ($KES_STATE). Alert may not fire."
fi
echo ""
echo "KES is now stopped. The kms-unavailable alert fires within 5 minutes."
echo "(The KMS monitor runs every 5 minutes; first check is immediate at startup)"
echo ""
echo "Next steps:"
echo "  ./verify.sh      # Poll for the kms-unavailable alert (waits up to 10 min)"
echo "  docker compose logs minio1-kms  # View MinIO logs"
echo "  docker compose down             # Stop and clean up"
