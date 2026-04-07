# Test Alerts

Docker-based test setups for MinIO AIStor alert external targets (Kafka and webhook).
Each scenario lives in its own directory and can be run independently.

| Scenario                  | Directory             | Alert type           |
| ------------------------- | --------------------- | -------------------- |
| TLS certificate expiry    | `.` (root)            | `certificate-expiry` |
| KMS unavailability        | `kms-unavailability/` | `kms-unavailable`    |
| Storage capacity critical | `storage-capacity/`   | `storage-capacity`   |
| Bootstrap config mismatch | `bootstrap-mismatch/` | `config-mismatch`    |

## Prerequisites

- Docker and Docker Compose
- Go 1.22+ (for the cert-gen tool in the root scenario)
- `openssl` (for KMS cert generation)
- `mc` (MinIO Client) — optional, for `mc alerts`
- A MinIO AIStor Docker image and license

## Configuration

All scenarios read credentials from a shared `.env` file in the repo root.

```bash
cp .env.sample .env
# Edit .env and set:
#   MINIO_IMAGE   - your MinIO AIStor Docker image
#   MINIO_LICENSE - your license key
```

Each scenario's `run.sh` writes a local `.env` inside its directory after
sourcing the root `.env`. This means `docker compose down|logs|ps` work from
the scenario directory without needing to source anything manually.

---

## Scenario 1 — TLS Certificate Expiry (root)

Tests `certificate-expiry` alerts when a TLS certificate is expired or expiring soon.

```bash
# Start with a certificate that expires in 3 days
./run.sh expiring

# Trigger test alerts
./generate.sh

# Verify alerts received
./verify.sh
```

**Certificate modes:**

```bash
./run.sh expiring   # cert expires in 3 days  → "TLS Certificate Expiring" alert
./run.sh expired    # cert already expired     → "TLS Certificate Expired" alert
./run.sh valid      # cert valid for 365 days  → no cert alert (baseline)
```

**Services:**

| Service       | URL                      | Notes                   |
| ------------- | ------------------------ | ----------------------- |
| MinIO API     | `https://localhost:9010` | TLS, self-signed        |
| MinIO Console | `https://localhost:9001` | minioadmin / minioadmin |
| Webhook       | `http://localhost:9090`  | alert receiver          |
| Kafka         | `localhost:9092`         | topic: `alert-events`   |

**Cleanup:**

```bash
docker compose down
```

---

## Scenario 2 — KMS Unavailability (`kms-unavailability/`)

Tests the `kms-unavailable` alert. Runs a 4-node MinIO cluster backed by a MinIO
KES instance. Once the cluster is healthy, KES is stopped to simulate KMS
unavailability. The alert fires within 5 minutes (the KMS monitor interval).

**How it works:**

1. `run.sh` generates mTLS certificates: a CA, a dedicated KES admin cert, and a
   MinIO client cert. Two separate identities are required because KES rejects
   configs where the same identity appears in both `admin.identity` and a policy.
2. KES is started with an `fs` keystore and the MinIO client identity in its policy.
3. MinIO is configured with `MINIO_KMS_KES_*` env vars pointing at KES.
4. `run.sh` waits for KES to accept mTLS connections (using the MinIO client cert),
   then waits for the MinIO cluster to become healthy.
5. KES is stopped. The KMS monitor's next 5-minute tick detects all endpoints
   offline and fires the alert.

```bash
cd kms-unavailability/

# Generate certs, start cluster + KES, wait for health, then stop KES
./run.sh

# Poll for the kms-unavailable alert (waits up to 10 minutes)
./verify.sh

# Cleanup
docker compose down
rm -rf certs/ config/
```

**Services:**

| Service       | URL                      | Notes                                        |
| ------------- | ------------------------ | -------------------------------------------- |
| MinIO API     | `http://localhost:9010`  | HTTP (no MinIO TLS in this scenario)         |
| MinIO Console | `http://localhost:9011`  | minioadmin / minioadmin                      |
| KES           | `https://localhost:7373` | stopped by `run.sh` after cluster is healthy |
| Webhook       | `http://localhost:9090`  | alert receiver                               |
| Kafka         | `localhost:9092`         | topic: `alert-events`                        |

**Architecture:**

```
  minio{1..4}  ──mTLS──►  KES :7373   (stopped after cluster is healthy)
       │
       └── alerts ──►  Webhook :9090
                   ──►  Kafka   :9092
```

> **Note:** Always run `docker compose down` between test runs. The
> `kms-unavailable` dedup key is held in-memory for 24 hours; restarting
> the containers resets it.

---

## Scenario 3 — Storage Capacity Critical (`storage-capacity/`)

Tests the `storage-capacity` alert. Each MinIO node gets two 50 MB tmpfs drives.
A custom entrypoint (`scripts/fill-and-start.sh`) fills each drive to 93% before
MinIO starts, leaving ~7% usable free space (below the 10% threshold). The alert
fires on the very first storage monitor check, immediately after leader election.

**How it works:**

1. Each node's entrypoint pre-fills `/data1` and `/data2` to 93% using `dd` and
   POSIX shell built-ins (`read` for parsing `df` output — `awk` is not available
   in the MinIO image). The fill completes in under a second.
2. MinIO starts and the leader's `checkAndAlertStorageCapacity` fires immediately
   on the first `runLeaderMonitor` tick.
3. With EC:4 across 8 × 50 MB drives: ~200 MB usable total, ~14 MB usable free
   (~7%) → below the 10% threshold → alert fires.

The pre-fill approach is intentional: the storage monitor's next scheduled run
after the immediate startup check is 6 hours away. Pre-filling ensures the alert
fires on that first check rather than waiting for the 6-hour interval.

```bash
cd storage-capacity/

# Start cluster (drives are pre-filled; alert fires within ~2 minutes)
./run.sh

# Poll for the storage-capacity alert (waits up to 5 minutes)
./verify.sh

# Cleanup
docker compose down
```

**Services:**

| Service       | URL                     | Notes                   |
| ------------- | ----------------------- | ----------------------- |
| MinIO API     | `http://localhost:9010` |                         |
| MinIO Console | `http://localhost:9011` | minioadmin / minioadmin |
| Webhook       | `http://localhost:9090` | alert receiver          |
| Kafka         | `localhost:9092`        | topic: `alert-events`   |

---

## Scenario 4 — Bootstrap Config Mismatch (`bootstrap-mismatch/`)

Tests the `config-mismatch` alert fired during server bootstrap verification.
`minio4` is started with a configuration that differs from nodes 1–3. Once the
healthy majority (nodes 1–3) reaches bootstrap quorum, `minio1` fires a
`config-mismatch` alert identifying `minio4` as the misconfigured peer.

All three mismatch types that MinIO detects are supported via a positional argument:

| Type        | Command              | What differs on minio4                             | Error type                 |
| ----------- | -------------------- | -------------------------------------------------- | -------------------------- |
| `env`       | `./run.sh env`       | `MINIO_SITE_NAME=wrong-site`                       | `ErrEnvMismatch`           |
| `endpoints` | `./run.sh endpoints` | 3 drives (`data{1...3}`) instead of 2              | `ErrEndpointCountMismatch` |
| `args`      | `./run.sh args`      | Drive paths `disk{1...2}` instead of `data{1...2}` | `ErrArgsMismatch`          |

**How it works:**

1. All four nodes start simultaneously. Nodes 1–3 agree on configuration and
   reach bootstrap quorum among themselves (`verifyServerSystemConfig`).
2. `minio4` disagrees with every peer on a key configuration field and can never
   reach quorum. It stays stuck in its verification loop indefinitely — its
   healthcheck will permanently fail. This is expected and intentional.
3. `minio1` (`FirstLocal()` in the cluster topology) calls
   `sendBootstrapConfigMismatchAlerts` with `minio4`'s address and the error.
   `FirstLocal()` is used instead of the distributed leader lock because bootstrap
   verification runs before `newObjectLayer()` initialises the lock.
4. The alert fires within seconds of the healthy majority completing startup.

**`Diff()` check order** — MinIO stops at the first difference found:

```
NEndpoints (int)  →  ErrEndpointCountMismatch   ← endpoints scenario
CmdLines ([]string)  →  ErrArgsMismatch          ← args scenario
MinioEnv (map)  →  ErrEnvMismatch                ← env scenario
```

For `endpoints`: minio4 uses `http://minio{1...4}/data{1...3}` (4×3=12 endpoints)
vs 4×2=8 on peers → caught at step 1.

For `args`: minio4 uses `http://minio{1...4}/disk{1...2}` — same 8 endpoints but
different CmdLine string → passes step 1, caught at step 2. The `/disk1`/`/disk2`
paths never need to exist; minio4 is stuck in bootstrap before touching drives.

For `env`: command and endpoint counts are identical; only `MINIO_SITE_NAME`
differs → passes steps 1 and 2, caught at step 3.

```bash
cd bootstrap-mismatch/

# Environment variable mismatch (default)
./run.sh env
./verify.sh env

# Endpoint count mismatch
docker compose down
./run.sh endpoints
./verify.sh endpoints

# Startup arguments mismatch
docker compose down
./run.sh args
./verify.sh args

# Cleanup
docker compose down
```

> **Note:** `minio4` is the misconfigured node under test. It is stuck in bootstrap
> verification and never serves S3 traffic. nginx routes traffic only to the healthy
> majority (minio1–3).

**Services:**

| Service       | URL                     | Notes                   |
| ------------- | ----------------------- | ----------------------- |
| MinIO API     | `http://localhost:9010` | minio1–3 only           |
| MinIO Console | `http://localhost:9011` | minioadmin / minioadmin |
| Webhook       | `http://localhost:9090` | alert receiver          |
| Kafka         | `localhost:9092`        | topic: `alert-events`   |

---

## Inspecting Alerts

These commands work for all scenarios (substitute the correct Kafka container
name: `kafka`, `kafka-kms`, `kafka-storage`, or `kafka-mismatch`):

```bash
# Webhook stats
curl -s http://localhost:9090/stats | python3 -m json.tool

# All webhook entries
curl -s http://localhost:9090/entries | python3 -m json.tool

# Filter by alert type
curl -s http://localhost:9090/entries | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    if a.get('type') == 'kms-unavailable':   # change type as needed
        print(json.dumps(a, indent=2))
"

# Kafka messages
docker exec kafka-kms kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic alert-events \
  --from-beginning \
  --timeout-ms 5000

# MinIO internal alert log (requires mc alias)
mc alias set myminio http://localhost:9010 minioadmin minioadmin
mc admin alerts list myminio
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
