#!/bin/bash
# YubiKey PIV provisioning — fresh YubiKey 5 Series (firmware >= 5.7).
# Run interactively on macOS; requires ykman, OpenSSL, OpenSSH, YKCS11.
set -euo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
for cmd in ykman openssl ssh-keygen awk mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Missing executable: $cmd"
done

# Use an email address as the public-key comment and X.509 common name.
printf 'Email for SSH key comment: '
IFS= read -r EMAIL
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail 'Invalid email address'

# Require explicit, unambiguous token selection: exactly one connected YubiKey.
DEVICE_INFO="$(ykman list --serials)" || fail 'Cannot enumerate YubiKeys'
SERIAL="$(printf '%s\n' "$DEVICE_INFO" | awk 'NF {print $1}')"
[[ "$(printf '%s\n' "$SERIAL" | awk 'NF {n++} END {print n+0}')" == 1 ]] || fail 'Connect exactly one YubiKey'
SERIAL="$(printf '%s\n' "$SERIAL" | awk 'NF {print; exit}')"

INFO="$(ykman --device "$SERIAL" info)" || fail 'Cannot read YubiKey information'
FIRMWARE="$(printf '%s\n' "$INFO" | awk -F: '/Firmware version:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
[[ "$FIRMWARE" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail 'Cannot determine firmware version'
MAJOR="${FIRMWARE%%.*}"; VREST="${FIRMWARE#*.}"; MINOR="${VREST%%.*}"
(( MAJOR > 5 || (MAJOR == 5 && MINOR >= 7) )) || fail 'Firmware 5.7+ required'

PROVIDER=''
for candidate in /usr/local/lib/libykcs11.dylib /opt/homebrew/lib/libykcs11.dylib; do
    if [[ -r "$candidate" ]]; then PROVIDER="$candidate"; break; fi
done
[[ -n "$PROVIDER" ]] || fail 'libykcs11.dylib missing: install Yubico PIV Tool'

# Do not overwrite an existing PIV private key.
if ykman --device "$SERIAL" piv keys info 9a >/dev/null 2>&1; then
    fail 'PIV slot 9a already contains a key: refusing to overwrite'
fi

# The operator must be able to write to the current working directory, not script directory.
SAFE_EMAIL="${EMAIL//@/_}"; SAFE_EMAIL="${SAFE_EMAIL//[^a-zA-Z0-9._-]/_}"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUTPUT="$PWD/yubikey-piv-${SAFE_EMAIL}-${SERIAL}-${STAMP}.txt"
[[ ! -e "$OUTPUT" ]] || fail "Output already exists: $OUTPUT"

# Hex encodings avoid non-ASCII PIN interoperability problems.
PIN="$(openssl rand -hex 4)"          # 8 characters, 32 bits
PUK="$(openssl rand -hex 4)"          # 8 characters, 32 bits
MGMT="$(openssl rand -hex 24)"        # AES-192, 48 hex characters
DEFAULT_PIN=123456
DEFAULT_PUK=12345678
DEFAULT_MGMT=010203040506070801020304050607080102030405060708

# Save recovery material before changing the device; retain on failure to allow recovery.
( set -o noclobber; : > "$OUTPUT" ) || fail "Cannot create: $OUTPUT"
chmod 600 "$OUTPUT"
cat > "$OUTPUT" <<RECORD
YUBIKEY PIV PROVISIONING RECORD
STATUS: IN PROGRESS — DO NOT RELY ON KEY UNTIL SUCCESS
Key comment email: $EMAIL
YubiKey serial: $SERIAL
Firmware: $FIRMWARE
Date (UTC): $STAMP
PIV slot: 9a
Algorithm: ED25519
PIN policy: ONCE
Touch policy: ALWAYS
PIN retries: 10
PUK retries: 5
Temporary PIV PIN: $PIN
Recovery PUK: $PUK
PIV Management Key (AES-192, hex): $MGMT

SSH public key: PENDING
SSH fingerprint: PENDING
RECORD
printf '\nProvisioning record: %s\n' "$OUTPUT"
printf 'SECURITY: This plaintext record contains PIN, PUK and Management Key. Store offline/encrypted, never commit it to Git, and securely delete the plaintext copy.\n\n'

# Use the selected serial for every ykman operation.
yk() { ykman --device "$SERIAL" "$@"; }
TMPDIR_PRIVATE="$(mktemp -d "${TMPDIR:-/tmp/}yubikey-piv.XXXXXXXX")"
cleanup() { rm -rf "$TMPDIR_PRIVATE"; }
trap cleanup EXIT
PUBTMP="$TMPDIR_PRIVATE/piv-9a.pem"

log 'Configuring retry counts (PIN 10, PUK 5)'
yk piv access set-retries --force --management-key "$DEFAULT_MGMT" --pin "$DEFAULT_PIN" 10 5
log 'Installing random PIN and PUK'
yk piv access change-puk --puk "$DEFAULT_PUK" --new-puk "$PUK"
yk piv access change-pin --pin "$DEFAULT_PIN" --new-pin "$PIN"
log 'Installing AES-192 PIV Management Key'
yk piv access change-management-key --force --algorithm AES192 \
    --management-key "$DEFAULT_MGMT" --new-management-key "$MGMT"

log 'Generating non-exportable PIV Ed25519 key with PIN ONCE / TOUCH ALWAYS'
yk piv keys generate --algorithm ED25519 --pin-policy ONCE --touch-policy ALWAYS \
    --management-key "$MGMT" --pin "$PIN" 9a "$PUBTMP"

log 'Generating PIV X.509 certificate (touch the YubiKey when it flashes)'
yk piv certificates generate --subject "CN=$EMAIL" --valid-days 3650 \
    --management-key "$MGMT" --pin "$PIN" 9a "$PUBTMP"

log 'Verifying PIV key metadata'
POLICIES="$(yk piv keys info 9a)"
printf '%s\n' "$POLICIES" | grep -Eiq 'ed25519' || fail 'Slot 9a algorithm check failed'
printf '%s\n' "$POLICIES" | grep -Eiq 'PIN (policy|required for use):[[:space:]]*Once' || fail 'PIN policy is not ONCE'
printf '%s\n' "$POLICIES" | grep -Eiq 'Touch (policy|required for use):[[:space:]]*Always' || fail 'Touch policy is not ALWAYS'
printf '%s\n' "$POLICIES" | grep -Eiq 'Origin:[[:space:]]*generated' || fail 'Key generation origin could not be confirmed'

log 'Exporting public SSH key using YKCS11'
# An installed YKCS11 build may not export PIV Ed25519, even on firmware 5.7+.
KEYS="$(ssh-keygen -D "$PROVIDER")" || fail 'YKCS11 public-key enumeration failed'
SSH_PUB="$(printf '%s\n' "$KEYS" | awk -v email="$EMAIL" '$1 == "ssh-ed25519" {print $1, $2, email; exit}')"
[[ -n "$SSH_PUB" ]] || fail 'YKCS11 did not expose Ed25519; token configured but macOS SSH compatibility not verified'
SSH_FINGERPRINT="$(printf '%s\n' "$SSH_PUB" | ssh-keygen -lf -)" || fail 'Cannot calculate SSH fingerprint'

# Rewrite the designated placeholders without displaying secrets again.
awk -v pub="$SSH_PUB" -v fp="$SSH_FINGERPRINT" '
  /^SSH public key: PENDING$/ {print "SSH public key: " pub; next}
  /^SSH fingerprint: PENDING$/ {print "SSH fingerprint: " fp; next}
  /^STATUS: IN PROGRESS/ {print "STATUS: PROVISIONED (live SSH and Git signing validation pending)"; next}
  {print}
' "$OUTPUT" > "$TMPDIR_PRIVATE/record"
cat "$TMPDIR_PRIVATE/record" > "$OUTPUT"

log 'Provisioning finished'
printf '\nRecord: %s\n' "$OUTPUT"
printf 'SSH fingerprint: %s\n' "$SSH_FINGERPRINT"
printf 'NEXT: perform real SSH-authentication and Git-SSH-signing tests; change the temporary PIV PIN to your own PIN before use or handover.\n'
