# Test Alerts

Docker-based test setup for MinIO AIStor alert external targets (Kafka and webhook), with TLS certificate expiry alert testing. Runs a 4-node distributed MinIO cluster behind an nginx load balancer.

## Prerequisites

- Docker and Docker Compose
- Go 1.22+
- `mc` (MinIO Client) for `mc alerts` command
- A MinIO AIStor Docker image and license

## Quick Start

```bash
# 1. Configure
cp .env.sample .env
# Edit .env: set MINIO_IMAGE and MINIO_LICENSE

# 2. Start with expiring certificate (triggers alert)
./run.sh expiring

# 3. Trigger test alerts
./generate.sh

# 4. Verify alerts arrived in Kafka and webhook
./verify.sh
```

## Certificate Modes

```bash
./run.sh expiring   # cert expires in 3 days (triggers "TLS Certificate Expiring" alert)
./run.sh expired    # cert already expired (triggers "TLS Certificate Expired" alert)
./run.sh valid      # cert valid for 365 days (no cert alert, baseline test)
```

To switch modes, tear down and re-run:

```bash
docker compose down
./run.sh expired
```

## Scripts

| Script              | Description                                         |
| ------------------- | --------------------------------------------------- |
| `run.sh`            | Start all services with a cert mode                 |
| `generate.sh`       | Trigger test alerts via `/minio/health/test-alerts` |
| `verify.sh`         | Check alerts received in Kafka and webhook          |
| `generate-certs.sh` | Generate TLS certs (called by `run.sh`)             |

## Architecture

```
                    ┌──────────────────┐
                    │      nginx       │
                    │  :9010 (API)     │
                    │  :9001 (Console) │
                    └────────┬─────────┘
                             │ L4 TCP passthrough
              ┌──────┬───────┴───────┬──────┐
              ▼      ▼               ▼      ▼
           minio1  minio2        minio3  minio4
           (HTTPS) (HTTPS)       (HTTPS) (HTTPS)
              │                             │
              └──────────┬──────────────────┘
                         │ alerts
                   ┌─────┴─────┐
                   ▼           ▼
                Webhook      Kafka
                :9090        :9092
```

## Services

| Service        | URL                       | Description                          |
| -------------- | ------------------------- | ------------------------------------ |
| MinIO API      | `https://localhost:9010`  | S3 API via nginx (TLS, self-signed)  |
| MinIO Console  | `https://localhost:9001`  | Web UI (minioadmin/minioadmin)       |
| Webhook        | `http://localhost:9090`   | Alert webhook receiver               |
| Kafka          | `localhost:9092`          | Kafka broker (topic: `alert-events`) |

## Inspecting Alerts

```bash
# Webhook stats
curl -s http://localhost:9090/stats | python3 -m json.tool

# Webhook entries
curl -s http://localhost:9090/entries | python3 -m json.tool

# Kafka messages
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic alert-events \
  --from-beginning \
  --timeout-ms 5000

# MinIO internal alerts (requires mc alias)
mc alias set myminio https://localhost:9010 minioadmin minioadmin --insecure
mc alerts myminio --insecure

# MinIO logs
docker compose logs minio1 minio2 minio3 minio4
docker compose logs webhook
```

## .env Configuration

```bash
# Required
MINIO_IMAGE=<your-minio-aistor-image>
MINIO_LICENSE=<your-license-key>

# Optional
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
_MINIO_SUBNET_URL=http://host.docker.internal:9000
MINIO_CALLHOME_ENABLE=off
```

## Cleanup

```bash
docker compose down
```
