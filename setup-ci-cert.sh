#!/bin/bash
# Run this yourself, locally, once — it exports the "StkhMonitor Local Signing"
# certificate from your login keychain and uploads it to this repo's GitHub
# Actions secrets, so CI-built DMGs are signed with the same stable identity
# as your local builds (keeps Full Disk Access etc. from breaking on update).
#
# It needs your `gh` CLI to already be authenticated (`gh auth status`).
set -e
cd "$(dirname "$0")"

CERT_NAME="StkhMonitor Local Signing"
REPO="brekhov-i/stkh-monitoring"

echo "Сертификаты, которые будут экспортированы из твоего login keychain:"
security find-certificate -a -c "" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
    | grep '"labl"' | sed 's/^/  /'
echo
echo "'security export -t identities' экспортирует ВСЕ пары сертификат+приватный ключ"
echo "из login keychain, не только '$CERT_NAME'. Проверь список выше — если там есть"
echo "лишнее (например, старые Developer ID сертификаты), лучше прерви (Ctrl+C) и"
echo "сначала удали ненужное в Keychain Access."
read -p "Продолжить экспорт? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

TMPDIR_EXPORT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_EXPORT"' EXIT

P12_PASS="$(openssl rand -base64 24)"

security export -k "$HOME/Library/Keychains/login.keychain-db" \
    -t identities \
    -f pkcs12 \
    -P "$P12_PASS" \
    -o "$TMPDIR_EXPORT/stkh-cert.p12"

base64 -i "$TMPDIR_EXPORT/stkh-cert.p12" | gh secret set MACOS_CERT_P12 --repo "$REPO"
printf '%s' "$P12_PASS" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"

echo "Готово: secrets MACOS_CERT_P12 и MACOS_CERT_PASSWORD добавлены в $REPO."
