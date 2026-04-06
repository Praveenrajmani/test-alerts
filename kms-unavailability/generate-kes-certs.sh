#!/bin/bash
# Generates all certificates needed for the KES mTLS setup:
#   ca.crt / ca.key             - Root CA (trusted by both KES server and MinIO)
#   kes-server.crt / .key       - KES server TLS certificate (signed by CA)
#   kes-admin.crt / .key        - KES admin identity (used only in admin.identity)
#   minio-kes-client.crt / .key - MinIO's mTLS client certificate (signed by CA)
#   kes-admin-identity.txt      - KES identity hash for the admin cert
#   minio-kes-identity.txt      - KES identity hash for the MinIO client cert
#
# KES does not allow the same identity to appear in both admin.identity and a
# policy, so two separate certs are generated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"

mkdir -p "$CERTS_DIR"

kes_identity() {
    # KES identity = SHA-256 of the DER-encoded SubjectPublicKeyInfo.
    # Equivalent to `kes identity of <cert>`.
    openssl x509 -in "$1" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 2>/dev/null \
        | awk '{print $2}'
}

echo "Generating test CA..."
openssl genrsa -out "$CERTS_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=test-ca" 2>/dev/null

echo "Generating KES server certificate..."
openssl genrsa -out "$CERTS_DIR/kes-server.key" 2048 2>/dev/null
openssl req -new \
    -key "$CERTS_DIR/kes-server.key" \
    -out "$CERTS_DIR/kes-server.csr" \
    -subj "/CN=kes" 2>/dev/null
# SAN extension so MinIO's TLS verification accepts the hostname "kes"
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/kes-server.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/kes-server.crt" \
    -extfile <(printf "subjectAltName=DNS:kes,DNS:localhost,IP:127.0.0.1") 2>/dev/null

echo "Generating KES admin certificate..."
openssl genrsa -out "$CERTS_DIR/kes-admin.key" 2048 2>/dev/null
openssl req -new \
    -key "$CERTS_DIR/kes-admin.key" \
    -out "$CERTS_DIR/kes-admin.csr" \
    -subj "/CN=kes-admin" 2>/dev/null
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/kes-admin.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/kes-admin.crt" 2>/dev/null

echo "Generating MinIO KES client certificate..."
openssl genrsa -out "$CERTS_DIR/minio-kes-client.key" 2048 2>/dev/null
openssl req -new \
    -key "$CERTS_DIR/minio-kes-client.key" \
    -out "$CERTS_DIR/minio-kes-client.csr" \
    -subj "/CN=minio" 2>/dev/null
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/minio-kes-client.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/minio-kes-client.crt" 2>/dev/null

ADMIN_IDENTITY=$(kes_identity "$CERTS_DIR/kes-admin.crt")
MINIO_IDENTITY=$(kes_identity "$CERTS_DIR/minio-kes-client.crt")

echo "$ADMIN_IDENTITY" > "$CERTS_DIR/kes-admin-identity.txt"
echo "$MINIO_IDENTITY" > "$CERTS_DIR/minio-kes-identity.txt"

echo ""
echo "Certificates ready:"
echo "  CA:            $CERTS_DIR/ca.crt"
echo "  KES server:    $CERTS_DIR/kes-server.crt / kes-server.key"
echo "  KES admin:     $CERTS_DIR/kes-admin.crt  (identity: $ADMIN_IDENTITY)"
echo "  MinIO client:  $CERTS_DIR/minio-kes-client.crt  (identity: $MINIO_IDENTITY)"
