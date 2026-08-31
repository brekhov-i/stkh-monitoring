#!/bin/bash
set -ex

CERT_NAME="StkhMonitor Local Signing"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "Сертификат '$CERT_NAME' уже есть в связке ключей."
    exit 0
fi

if [ "$CI" = "true" ]; then
    # GitHub-hosted runners' default login keychain has an unreliable lock
    # state for non-interactive codesign right after import — use our own
    # keychain with a password we control instead, same as the secret-based
    # cert import path in release.yml.
    KEYCHAIN="${RUNNER_TEMP:-/tmp}/stkh-fallback.keychain-db"
    KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    EXISTING=$(security list-keychains -d user | sed 's/[[:space:]]*"\(.*\)"/\1/')
    security list-keychains -d user -s "$KEYCHAIN" $EXISTING
else
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
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
    -k "$KEYCHAIN" \
    -P stkhmonitor \
    -T /usr/bin/codesign \
    -T /usr/bin/security

if [ "$CI" = "true" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi

echo "Сертификат '$CERT_NAME' создан и импортирован."
