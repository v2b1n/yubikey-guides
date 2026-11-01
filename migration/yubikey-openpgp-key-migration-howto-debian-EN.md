# HowTo: Migrate an Existing OpenPGP Key to YubiKey

Current working procedure:

```text
reset
→ key-attr RSA4096
→ kdf-setup
→ keytocard primary
→ keytocard encryption
→ touch policies
→ functional tests
→ change User PIN
→ change Admin PIN
```

Rationale: all administrative operations are performed using the factory-default PINs, and the final long PINs are set only at the very end.

## 1. Original Backup

A **full backup of `~/.gnupg`, created before the first `keytocard` operation**, is required, while the private key material was still stored on disk.

Example:

```bash
tar -C "$HOME" -czf gnupg-backup.tar.gz .gnupg
```

After migrating the keys to the YubiKey, the regular `~/.gnupg` contains card stubs and is no longer a complete master backup of the private keys.

## 2. Prepare a Temporary GNUPGHOME

```bash
export YKHOME=/dev/shm/yk-gnupg

rm -rf "$YKHOME"
mkdir -m 700 "$YKHOME"
```

Extract the original pre-YubiKey backup into it.

If the backup contains `.gnupg`:

```bash
tar -C /dev/shm -xzf gnupg-backup.tar.gz
cp -a /dev/shm/.gnupg/. "$YKHOME"/
rm -rf /dev/shm/.gnupg
```

For operation via PC/SC:

```bash
cat > "$YKHOME/scdaemon.conf" <<'EOF'
disable-ccid
pcsc-shared
EOF

chmod 600 "$YKHOME/scdaemon.conf"
```

Restart the agent/scdaemon specifically for this home directory:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

Verify the private key material:

```bash
gpg --homedir "$YKHOME"   --list-secret-keys   --with-subkey-fingerprint   --keyid-format LONG
```

Before migration, the output should show:

```text
sec  ... [SC]
ssb  ... [E]
```

Without `>`.

## 3. Check the Intended YubiKey

```bash
ykman info
```

Make sure the serial number matches the intended device.

## 4. Reset Only the OpenPGP Applet, If Necessary

```bash
ykman openpgp reset
```

This resets only the OpenPGP applet and does not affect PIV/FIDO/OATH/OTP.

Factory-default credentials after a reset:

```text
User PIN:  123456
Admin PIN: 12345678
```

## 5. Set RSA4096 Key Attributes

```bash
gpg --card-edit
```

Inside the interactive prompt:

```text
admin
key-attr
```

Set:

```text
Signature      RSA 4096
Encryption     RSA 4096
Authentication RSA 4096
```

The Authentication slot may remain empty.

## 6. Enable OpenPGP KDF

Before the keys have been loaded:

```bash
gpg --card-edit
```

Inside the interactive prompt:

```text
admin
kdf-setup
```

Verify:

```bash
gpg --card-status
```

Expected output:

```text
KDF setting ......: on
PIN retry counter : 3 0 3
```

After `kdf-setup`, the factory-default PINs are used:

```text
User PIN:  123456
Admin PIN: 12345678
```

Setting a Reset Code is optional.

## 7. Ensure the Temporary GNUPGHOME Can Access the Card

```bash
gpg --homedir "$YKHOME" --card-status
```

If you see:

```text
gpg: selecting card failed: No such device
```

Check `$YKHOME/scdaemon.conf` and restart:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

## 8. Move the Primary `[SC]` Key to the Signature Slot

Example fingerprint:

```text
7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

```bash
gpg --homedir "$YKHOME"   --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Inside the interactive prompt:

```text
keytocard
```

Confirm the migration of the primary key and select:

```text
1 = Signature key
```

Current Admin PIN:

```text
12345678
```

Then:

```text
save
```

## 9. Move the Encryption Subkey `[E]`

Open the key again:

```bash
gpg --homedir "$YKHOME"   --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Select the encryption subkey:

```text
key 1
```

Make sure `*` marks the subkey with usage `[E]`.

Next:

```text
keytocard
```

Select:

```text
2 = Encryption key
```

And:

```text
save
```

## 10. Enable the Touch Policy

```bash
ykman openpgp keys set-touch SIG on
ykman openpgp keys set-touch ENC on
```

Verify:

```bash
gpg --card-status
```

Expected output:

```text
UIF setting ......: Sign=on Decrypt=on Auth=off
```

## 11. Check the Card Status

Preferably use the same temporary GNUPGHOME:

```bash
gpg --homedir "$YKHOME" --card-status
```

Example:

```text
Serial number ....: 12345678
Key attributes ...: rsa4096 rsa4096 rsa4096
PIN retry counter : 3 0 3
KDF setting ......: on
UIF setting ......: Sign=on Decrypt=on Auth=off

Signature key ....: ...
Encryption key....: ...

sec> ... card-no: 0006 12345678
ssb> ... card-no: 0006 12345678
```

## 12. Functional Test Before the Final PIN Changes

Signing:

```bash
date > /tmp/pgp-test.txt

gpg --homedir "$YKHOME"   --detach-sign /tmp/pgp-test.txt
```

Decryption:

```bash
echo "decrypt test" > /tmp/pgp-plain.txt

gpg --homedir "$YKHOME"   --recipient 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901   --encrypt /tmp/pgp-plain.txt

gpg --homedir "$YKHOME"   --decrypt /tmp/pgp-plain.txt.gpg
```

Both operations must work and require a physical touch.

## 13. Only Now Change the User PIN

```bash
gpg --card-edit
```

Inside the interactive prompt:

```text
admin
passwd
1
```

Current User PIN:

```text
123456
```

Set the final long alphanumeric User PIN.

## 14. Then Change the Admin PIN

In the same menu:

```text
3
```

Current Admin PIN:

```text
12345678
```

Set a separate long Admin PIN.

Important: the Admin PIN cannot be recovered using the Reset Code. If the Admin PIN becomes blocked, the OpenPGP applet must be reset and the keys must be migrated again from the backup.

## 15. Reset Code — Optional

It can be set using:

```text
gpg --card-edit
admin
passwd
4
```

However, it is only needed to recover the User PIN.

It:

```text
DOES NOT recover the Admin PIN
Is NOT mandatory
```

Normal state without a Reset Code:

```text
PIN retry counter : 3 0 3
```

## 16. Final Verification

```bash
gpg --card-status
```

Expected output:

```text
PIN retry counter : 3 0 3
KDF setting ......: on
UIF setting ......: Sign=on Decrypt=on Auth=off
```

Test signing and decryption again using the final User PIN.

## 17. Cleanup

After a successful test:

```bash
rm -rf "$YKHOME"
```

## 18. For a Second/Third YubiKey

Repeat the process **starting again from the original pre-YubiKey backup**, not from the temporary keyring, which has already been converted to card stubs.

Working procedure:

```text
reset
→ key-attr RSA4096
→ kdf-setup
→ keytocard primary
→ keytocard encryption
→ touch SIG/ENC
→ sign/decrypt test
→ change User PIN
→ change Admin PIN
→ final test
```

## Quick Checklist

```text
[ ] YubiKey serial number verified
[ ] OpenPGP reset performed if necessary
[ ] RSA4096 attributes set
[ ] KDF enabled
[ ] Temporary GNUPGHOME can access the card
[ ] Primary [SC] key moved to the Signature slot
[ ] Encryption [E] subkey moved to the Encryption slot
[ ] Touch SIG enabled
[ ] Touch ENC enabled
[ ] Signing test works
[ ] Decryption test works
[ ] User PIN changed to the final value
[ ] Admin PIN changed to the final value
[ ] PIN retry counter = 3 0 3
[ ] KDF = on
[ ] UIF = Sign=on Decrypt=on Auth=off
[ ] Temporary GNUPGHOME deleted
```
