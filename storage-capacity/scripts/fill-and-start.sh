#!/bin/sh
# Fills each MinIO data directory to 93% capacity before starting MinIO.
#
# Why: The storage-capacity alert monitor calls checkAndAlertStorageCapacity
# immediately when leadership is acquired (first run of runLeaderMonitor).
# Pre-filling ensures usable free space is already below the 10% threshold
# on that first check, so the alert fires within minutes of cluster startup
# rather than waiting for the 6-hour scheduled interval.
#
# Each data directory is mounted as a 50MB tmpfs. After filling 93% (~46MB),
# approximately 3.5MB remains for MinIO's own metadata (.minio.sys, format, IAM),
# which is sufficient for a fresh cluster. The fill itself takes under a second.
set -e

FILL_PCT=93

for dir in /data1 /data2; do
    mkdir -p "$dir"
    # Parse total KB from df using only shell built-ins — awk/cut are not
    # available in the MinIO image. `read` splits on whitespace natively.
    # df -k output: Filesystem  1K-blocks  Used  Available  Use%  Mounted
    TOTAL_KB=$(df -k "$dir" | { read _hdr; read _fs total _rest; echo "$total"; })
    FILL_KB=$((TOTAL_KB * FILL_PCT / 100))
    printf "  Pre-filling %s: %s KB of %s KB (%s%%)...\n" \
        "$dir" "$FILL_KB" "$TOTAL_KB" "$FILL_PCT"
    dd if=/dev/zero of="$dir/fill.dat" bs=1024 count="$FILL_KB" 2>/dev/null
    printf "  %s: done (%s KB free)\n" "$dir" "$((TOTAL_KB - FILL_KB))"
done

# Start MinIO with whatever arguments were passed to this script
exec minio "$@"
