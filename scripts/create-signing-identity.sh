#!/bin/bash
# Sets up a self-signed code-signing identity, "TabWM Local Signing", in the login keychain.
#
# Why: ad-hoc signatures change with every build, and macOS ties Accessibility and Input
# Monitoring grants to the exact build. Signing with one stable certificate keeps those
# grants valid across rebuilds. The certificate is only used locally.
#
# Run this in Terminal (not from an editor), because macOS may ask for your login password
# to trust the certificate and to let codesign use the key. Safe to run again.
#
# Remove everything later with:
#   security delete-identity -c "TabWM Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="TabWM Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  # The system LibreSSL writes PKCS#12 files that `security import` accepts.
  OPENSSL=/usr/bin/openssl
  cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = TabWM Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  "$OPENSSL" req -new -x509 -nodes -newkey rsa:2048 -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  PASS="tabwm-$RANDOM$RANDOM"
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASS" -out "$WORK/identity.p12" 2>/dev/null
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
  echo "Created \"$NAME\"."
else
  echo "\"$NAME\" already exists."
fi

# Trust the certificate for code signing (asks for your password once).
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Let codesign use the private key without a prompt on every build (asks for your password).
read -r -s -p "Login keychain password (lets codesign use the key without prompting): " KEYCHAIN_PASSWORD; echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Ready: \"$NAME\" is a valid code-signing identity. Rebuild with ./scripts/build-app.sh."
else
  echo "The certificate exists but isn't valid for code signing yet. Open Keychain Access, find \"$NAME\", and set Trust → Code Signing to Always Trust." >&2
  exit 1
fi
