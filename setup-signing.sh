#!/bin/bash
# Creates a self-signed code-signing identity so VoiceMac keeps a stable code
# signature across rebuilds.
#
# Why this matters: macOS ties three things to an app's code signature —
# the Accessibility grant, the Microphone grant, and Keychain item ACLs.
# Ad-hoc signing (`codesign -s -`) produces a different signature on every
# build, so all three are revoked each time you rebuild. That is why the
# "VoiceMac wants to use your confidential information" prompt keeps coming
# back and why Accessibility has to be re-granted.
#
# Run once:   ./setup-signing.sh
# Then build: SIGN_ID="VoiceMac Dev" ./build.sh
#
# Expect one or two macOS password prompts. They are the system authorising a
# new certificate into your keychain and marking it trusted for code signing.
#
# Implementation note: the certificate and key are imported as separate PEM
# files rather than as a PKCS#12 bundle. macOS ships LibreSSL, whose PKCS#12
# output fails Apple's Security framework MAC check ("MAC verification failed
# during PKCS12 import"), so the bundle route cannot be made to work here.
set -euo pipefail

cd "$(dirname "$0")"

IDENTITY="${1:-VoiceMac Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

note() { printf '==> %s\n' "$1"; }

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    note "Identity \"$IDENTITY\" already exists and is valid."
    echo
    echo "Build with:  SIGN_ID=\"$IDENTITY\" ./build.sh"
    exit 0
fi

note "generating a self-signed code-signing certificate: $IDENTITY"

# extendedKeyUsage=codeSigning is what makes this usable as a signing identity.
cat > "$WORKDIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = $IDENTITY

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -days 3650 \
    -config "$WORKDIR/openssl.cnf" 2>/dev/null

note "importing the private key and certificate into your login keychain"
echo "    (macOS may ask for your login password)"
# -T /usr/bin/codesign puts codesign on the key's access list so signing does
# not raise a prompt on every build.
security import "$WORKDIR/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$WORKDIR/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign

note "marking the certificate trusted for code signing"
echo "    (macOS will ask for your login password)"
# No -d: this writes user-level trust, which codesign honours and which does
# not require administrator rights. Without this step the identity reports
# CSSMERR_TP_NOT_TRUSTED and codesign says "no identity found".
if ! security add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$KEYCHAIN" \
        "$WORKDIR/cert.pem"; then
    echo
    echo "The trust step did not complete."
    echo "Open Keychain Access, find \"$IDENTITY\" under login > My Certificates,"
    echo "expand Trust, and set \"Code Signing\" to \"Always Trust\"."
    exit 1
fi

echo
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    note "Done — \"$IDENTITY\" is a valid signing identity."
    echo
    echo "Rebuild with it now:"
    echo "    SIGN_ID=\"$IDENTITY\" ./build.sh"
    echo
    echo "On that first signed build you will be asked once more for the"
    echo "Keychain and Accessibility permissions. Grant them (choose"
    echo "\"Always Allow\" for the Keychain) and they will persist across"
    echo "every later rebuild."
else
    echo "Certificate imported but still not reporting as valid."
    security find-identity -p codesigning | grep -i "$IDENTITY" || true
    echo
    echo "Open Keychain Access, find \"$IDENTITY\", expand Trust, and set"
    echo "\"Code Signing\" to \"Always Trust\"."
    exit 1
fi
