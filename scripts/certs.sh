#!/usr/bin/env bash
# Generates the private CA, the WAHA server certificate and the Lambda client certificate
# used for mutual TLS between the AWS Lambdas and the WAHA mTLS proxy.
#
# Usage: scripts/certs.sh <waha-hostname> [output-dir]
#   e.g. scripts/certs.sh waha.example.com
#
# The CA is created once and reused on later runs (rotation re-issues the server and
# client certs only). Keep ca.key offline: it is never needed in the cluster or in AWS.
set -euo pipefail

host="${1:?usage: $0 <waha-hostname> [output-dir]}"
out="${2:-certs}"
days="${CERT_DAYS:-397}"

mkdir -p "$out"
cd "$out"
umask 077

if [[ ! -f ca.key ]]; then
  echo "Creating private CA (valid 10 years)"
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 \
    -subj "/CN=MHACS Verify WAHA CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.crt
fi

issue() {
  local name="$1" subject="$2" ext="$3"
  openssl ecparam -name prime256v1 -genkey -noout -out "$name.key"
  openssl req -new -key "$name.key" -subj "$subject" -out "$name.csr"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$days" -sha256 -extfile <(printf '%b' "$ext") -out "$name.crt"
  rm -f "$name.csr"
}

echo "Issuing server certificate for $host (valid $days days)"
issue server "/CN=$host" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:$host\n"

echo "Issuing Lambda client certificate (valid $days days)"
issue client "/CN=mhacs-verify-lambda" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n"

openssl verify -CAfile ca.crt server.crt client.crt

cat <<NEXT

Done. Files in $(pwd):
  ca.crt      CA certificate (cluster + Lambdas)
  ca.key      CA private key  (keep offline, never upload)
  server.*    WAHA mTLS proxy certificate
  client.*    Lambda client certificate

Store in OpenBao (Argo CD fills the waha-mtls Secret via argocd-vault-plugin):
  bao kv put kv/k8s/mhacs-verify/waha-mtls \\
    tls_crt=@$(pwd)/server.crt tls_key=@$(pwd)/server.key ca_crt=@$(pwd)/ca.crt
Then Hard Refresh + sync the Argo CD app and restart deploy/waha if Reloader isn't installed.
NEXT
