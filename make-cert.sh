#!/bin/bash
set -e

CERT_NAME="StkhMonitor Local Signing"

if security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    echo "Сертификат '$CERT_NAME' уже есть в связке ключей."
    exit 0
fi

TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT

openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"

openssl pkcs12 -export \
    -out "$TMPDIR_CERT/cert.p12" \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -passout pass:stkhmonitor

security import "$TMPDIR_CERT/cert.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P stkhmonitor \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "Сертификат '$CERT_NAME' создан и импортирован."
