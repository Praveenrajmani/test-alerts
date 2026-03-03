package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	mode := flag.String("mode", "expiring", "Certificate validity mode: expiring|expired|valid")
	outDir := flag.String("out", "./certs", "Output directory for public.crt and private.key")
	hosts := flag.String("host", "minio,localhost,127.0.0.1", "Comma-separated SANs (DNS names and IPs)")
	flag.Parse()

	now := time.Now()
	var notBefore, notAfter time.Time

	switch *mode {
	case "expiring":
		notBefore = now
		notAfter = now.Add(3 * 24 * time.Hour) // expires in 3 days
	case "expired":
		notBefore = now.Add(-48 * time.Hour) // started 2 days ago
		notAfter = now.Add(-1 * time.Hour)   // expired 1 hour ago
	case "valid":
		notBefore = now
		notAfter = now.Add(365 * 24 * time.Hour) // valid for 1 year
	default:
		fmt.Fprintf(os.Stderr, "Unknown mode %q. Use: expiring, expired, or valid\n", *mode)
		os.Exit(1)
	}

	if err := generateCert(*outDir, *hosts, notBefore, notAfter); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Certificate generated (mode: %s)\n", *mode)
	fmt.Printf("  NotBefore: %s\n", notBefore.Format(time.RFC3339))
	fmt.Printf("  NotAfter:  %s\n", notAfter.Format(time.RFC3339))
}

func generateCert(outDir, hostList string, notBefore, notAfter time.Time) error {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate private key: %w", err)
	}

	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return fmt.Errorf("generate serial number: %w", err)
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName:         "minio",
			Organization:       []string{"MinIO"},
			OrganizationalUnit: []string{"Test Alerts"},
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	for _, h := range strings.Split(hostList, ",") {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		if ip := net.ParseIP(h); ip != nil {
			template.IPAddresses = append(template.IPAddresses, ip)
		} else {
			template.DNSNames = append(template.DNSNames, h)
		}
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, priv.Public(), priv)
	if err != nil {
		return fmt.Errorf("create certificate: %w", err)
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("create output dir: %w", err)
	}

	certPath := filepath.Join(outDir, "public.crt")
	certOut, err := os.Create(certPath)
	if err != nil {
		return fmt.Errorf("create %s: %w", certPath, err)
	}
	defer certOut.Close()
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		return fmt.Errorf("write cert: %w", err)
	}
	certOut.Close()

	keyPath := filepath.Join(outDir, "private.key")
	keyOut, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("create %s: %w", keyPath, err)
	}
	defer keyOut.Close()
	privBytes, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return fmt.Errorf("marshal private key: %w", err)
	}
	if err := pem.Encode(keyOut, &pem.Block{Type: "PRIVATE KEY", Bytes: privBytes}); err != nil {
		return fmt.Errorf("write key: %w", err)
	}
	keyOut.Close()

	return nil
}
