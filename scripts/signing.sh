#!/bin/zsh
# Stable local code-signing identity for PerfMonitor.
#
# Ad-hoc signatures are identified by the binary's hash, so macOS treats every rebuild as a
# new app and forgets permissions granted to the previous one. Signing with a fixed
# self-signed certificate keeps the identity ("local.perfmonitor" + certificate) stable.
#
# The certificate lives in its own keychain file under Application Support. It is not added
# to the keychain search list and no trust settings are changed.
#
# Usage: scripts/signing.sh <path-to-app>     (prints which identity was used)
set -euo pipefail

APP="$1"
DIR="$HOME/Library/Application Support/PerfMonitor/signing"
KC="$DIR/signing.keychain-db"
PASSFILE="$DIR/keychain-password"
NAME="PerfMonitor Local Signing"

if [[ ! -f "$KC" ]]; then
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    umask 077
    openssl rand -hex 24 > "$PASSFILE"
    TMP=$(mktemp -d)
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
    P12PASS=$(openssl rand -hex 12)
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PASS" 2>/dev/null \
        || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PASS"
    security create-keychain -p "$(cat "$PASSFILE")" "$KC"
    security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
    security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PASSFILE")" "$KC" >/dev/null 2>&1
    rm -rf "$TMP"
    echo "Created signing identity \"$NAME\" in $KC"
fi

security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
if codesign --force --keychain "$KC" --sign "$NAME" "$APP" 2>/dev/null; then
    echo "Signed with \"$NAME\""
else
    codesign --force --sign - "$APP"
    echo "warning: stable signing failed, fell back to ad-hoc (permissions will reset on rebuild)" >&2
fi
