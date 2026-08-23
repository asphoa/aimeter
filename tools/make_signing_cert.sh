#!/bin/bash
# Creates a local self-signed code-signing certificate and puts it in the login
# keychain, so every rebuild of AIMeter carries the SAME code identity.
#
# Why this matters: an ad-hoc signature (`codesign -s -`) identifies an app by
# the hash of its own bytes, so every rebuild looks to macOS like a different
# application and the keychain's "Always Allow" grant no longer matches. With a
# stable certificate, one grant holds across rebuilds.
#
# Reversible: delete "AIMeter Local Signing" in Keychain Access.
set -euo pipefail
NAME="${1:-AIMeter Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✅ already present: $NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
# macOS's importer cannot read OpenSSL 3's default AES/SHA-256 PKCS#12 MAC,
# so the bundle is written with the legacy algorithms it does understand.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:aimeter -name "$NAME" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

# -A lets codesign use the private key without a per-use prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P aimeter -A -T /usr/bin/codesign
# Trust it for code signing in the user's own trust settings (no admin needed).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || \
    echo "note: could not set trust settings automatically"

echo "--- identities now available ---"
security find-identity -v -p codesigning
