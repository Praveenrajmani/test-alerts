#!/bin/bash
set -e

MODE="${1:-expiring}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"

mkdir -p "$CERTS_DIR"
cd "$SCRIPT_DIR/certgen"
go run . -mode "$MODE" -out "$CERTS_DIR" -host "minio1,minio2,minio3,minio4,nginx,localhost,127.0.0.1"

if command -v openssl &>/dev/null; then
    echo ""
    echo "Certificate details:"
    openssl x509 -in "$CERTS_DIR/public.crt" -noout -dates -subject
fi
