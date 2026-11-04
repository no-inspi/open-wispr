#!/bin/zsh
# Compile, signe avec un certificat local stable, installe et relance open-wispr.
# Le certificat garde les permissions macOS d'une recompilation à l'autre :
# sans lui, le binaire est signé ad hoc et macOS l'identifie par son empreinte.
set -euo pipefail

NAME=open-wispr-local
KEYCHAIN=~/Library/Keychains/login.keychain-db
REPO=${0:A:h:h}
TARGET=~/.local/bin/open-wispr
SERVICE=gui/$(id -u)/com.charlie.open-wispr

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Création du certificat $NAME…"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    umask 077
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
    PASS=$(/usr/bin/openssl rand -hex 16)
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
fi

IDENTITY=$(security find-identity -p codesigning | awk -v n="$NAME" '$0 ~ n {print $2; exit}')
[[ -n "$IDENTITY" ]] || { echo "Certificat $NAME introuvable pour la signature." >&2; exit 1; }

cd "$REPO"
swift build -c release
codesign -f -s "$IDENTITY" --timestamp=none .build/release/open-wispr
codesign -v .build/release/open-wispr
cp .build/release/open-wispr "$TARGET"
launchctl kickstart -k "$SERVICE"

echo "Déployé. Exigence de signature :"
codesign -d -r- "$TARGET" 2>&1 | tail -1
