#!/bin/bash
# Creates a local self-signed code-signing certificate and puts it in the login
# keychain, so every rebuild of AIMeter carries the SAME code identity.
#
# Why this matters: an ad-hoc signature (`codesign -s -`) identifies an app by
# the hash of its own bytes, so every rebuild looks to macOS like a different
# application and the keychain's "Always Allow" grant no longer matches. With a
# stable certificate, one grant holds across rebuilds.
#
# To remove: in Keychain Access delete BOTH the certificate and the private key
# of the same name (they are separate rows under "login").
set -euo pipefail
NAME="${1:-AIMeter Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
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

# -T grants exactly one program (codesign) use of the private key. Do NOT add
# -A: that would let any process on this machine sign code with this key.
#
# The certificate is deliberately NOT added to the trust store either. A trust
# anchor is not needed for what this is for - verified: codesign signs happily
# with an untrusted self-signed identity, and the designated requirement still
# binds to this certificate's leaf hash, which is the thing that keeps the
# keychain's "Always Allow" valid across rebuilds. Making it a trusted
# code-signing anchor would instead mean anything signed with it passes
# "anchor trusted" checks on this Mac for the next ten years.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P aimeter -T /usr/bin/codesign

echo "--- certificate installed (untrusted by design; codesign can still use it) ---"
security find-certificate -c "$NAME" | grep -E '"labl"|"subj"' || true
