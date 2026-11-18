#!/bin/bash
# One-time: creates a self-signed code-signing identity in its own keychain, so rebuilt apps keep
# their macOS permissions (Screen Recording, Accessibility). Safe to re-run; it does nothing if set up.
# To remove: security delete-keychain "$KEYCHAIN" && rm -rf ~/.config/textgrabber
set -euo pipefail

NAME="TextGrabber Local Signing"
KEYCHAIN="$HOME/Library/Keychains/textgrabber-signing.keychain-db"
SECRET_DIR="$HOME/.config/textgrabber"
SECRET="$SECRET_DIR/signing-keychain-password"

if [ -f "$KEYCHAIN" ] && [ -f "$SECRET" ]; then
  echo "Signing identity already set up: $KEYCHAIN"
  exit 0
fi

mkdir -p "$SECRET_DIR" && chmod 700 "$SECRET_DIR"
( umask 077; /usr/bin/openssl rand -hex 24 > "$SECRET" )
PASSWORD="$(cat "$SECRET")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<CONF
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
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"                       # no auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

# Add it to the keychain search list without disturbing the others.
EXISTING=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
if ! echo "$EXISTING" | grep -qF "$KEYCHAIN"; then
  # shellcheck disable=SC2086
  IFS=$'\n' security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi
echo "Created signing identity \"$NAME\" in $KEYCHAIN"
