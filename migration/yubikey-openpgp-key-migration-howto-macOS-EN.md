# HowTo: Moving an existing OpenPGP key to a YubiKey (macOS)

Working order:

```text
RAM disk (macOS)
→ backup
→ reset
→ key-attr RSA4096
→ kdf-setup
→ keytocard primary
→ keytocard encryption
→ touch policies
→ functional tests
→ change User PIN
→ change Admin PIN
→ switch live keyring to card stubs
→ encrypt the original backup
→ cleanup
```

Logic: all administrative operations are done with the factory PINs, and the final long PINs are set only at the very end.

> **macOS notes** in this document mark places where macOS differs from Linux. Follow the macOS variant.

## 0. macOS: prerequisites and RAM disk

> **macOS:** there is no `/dev/shm`. Use a RAM disk instead, so the unencrypted backup and the temporary keyring never touch the SSD.

Check the tooling:

```bash
command -v gpg ykman
gpg --version | head -n 2
ykman --version
```

> **macOS:** GnuPG comes either from Homebrew (`/opt/homebrew/bin/gpg`) or from GPG Suite (`/usr/local/MacGPG2/bin/gpg`). Check which one is used; `pcsc-shared` (step 2) requires GnuPG 2.2.28+.

> **macOS:** if pinentry-mac shows a "Save in Keychain" checkbox for any PIN or passphrase prompt in this procedure, leave it **unchecked**.

Create a 256 MiB RAM disk:

```bash
YKRAM_DEV="$(hdiutil attach -nomount ram://524288 | awk '{print $1}')"
diskutil erasevolume HFS+ yk-ram "$YKRAM_DEV"
export YKRAM=/Volumes/yk-ram
sudo mdutil -i off "$YKRAM"
```

> **macOS:** if gpg later warns about unsafe ownership/permissions of the home directory, enable ownership on the volume: `sudo diskutil enableOwnership "$YKRAM"`.

## 1. Original backup

You need a **full backup of `~/.gnupg`, taken before the first `keytocard`**, while the private key material is still on disk.

```bash
gpgconf --kill gpg-agent
COPYFILE_DISABLE=1 tar -C "$HOME" --exclude 'S.*' -czf "$YKRAM/gnupg-backup.tar.gz" .gnupg
```

> **macOS:** write the archive to the RAM disk, not to `$HOME`. `COPYFILE_DISABLE=1` prevents `._*` AppleDouble files; `--exclude 'S.*'` skips agent sockets (bsdtar cannot archive them).

After the keys have been moved to the YubiKey, the regular `~/.gnupg` contains card stubs and is no longer a full master copy of the private keys.

## 2. Prepare a temporary GNUPGHOME

```bash
export YKHOME="$YKRAM/yk-gnupg"

rm -rf "$YKHOME"
mkdir -m 700 "$YKHOME"
```

Unpack the original pre-YubiKey backup into it.

If the backup contains `.gnupg`:

```bash
tar -C "$YKRAM" -xzf "$YKRAM/gnupg-backup.tar.gz"
cp -a "$YKRAM/.gnupg/." "$YKHOME"/
rm -rf "$YKRAM/.gnupg"
```

> **macOS:** paths changed from `/dev/shm` to `$YKRAM`; BSD `cp -a` works the same way.

For operation via PC/SC:

```bash
cat > "$YKHOME/scdaemon.conf" <<'EOF'
disable-ccid
pcsc-shared
EOF

chmod 600 "$YKHOME/scdaemon.conf"
```

> **macOS:** steps 5, 6, 10, 13-16 use the default home (`~/.gnupg`). Put the same `scdaemon.conf` into `~/.gnupg` as well, otherwise the default scdaemon may grab the YubiKey via its internal CCID driver and block both `ykman` and the temporary home. It is needed there for daily use anyway.
>
> ```bash
> cp "$YKHOME/scdaemon.conf" "$HOME/.gnupg/scdaemon.conf"
> chmod 600 "$HOME/.gnupg/scdaemon.conf"
> gpgconf --kill scdaemon
> ```

Restart agent/scdaemon for this specific home:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

Check the private material:

```bash
gpg --homedir "$YKHOME" --list-secret-keys --with-subkey-fingerprint --keyid-format LONG
```

Before the move it must show:

```text
sec  ... [SC]
ssb  ... [E]
```

without `>`.

## 3. Check the correct YubiKey

```bash
ykman info
```

Make sure the serial number is the right one.

## 4. If needed, reset only the OpenPGP applet

```bash
ykman openpgp reset
```

This resets only the OpenPGP applet and does not touch PIV/FIDO/OATH/OTP.

> **macOS:** if `ykman` cannot connect to the YubiKey, an scdaemon is holding it: run `gpgconf --kill scdaemon` and `gpgconf --homedir "$YKHOME" --kill scdaemon`, then retry. The same applies to step 10.

Factory credentials after reset:

```text
User PIN:  123456
Admin PIN: 12345678
```

## 5. Set RSA4096 attributes

```bash
gpg --card-edit
```

Inside:

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

The Authentication slot may stay empty.

## 6. Enable OpenPGP KDF

While no keys are loaded yet:

```bash
gpg --card-edit
```

Inside:

```text
admin
kdf-setup
```

Check:

```bash
gpg --card-status
```

Expected:

```text
KDF setting ......: on
PIN retry counter : 3 0 3
```

After `kdf-setup` the factory PINs are used:

```text
User PIN:  123456
Admin PIN: 12345678
```

The Reset Code does not need to be set.

## 7. Make sure the temporary GNUPGHOME sees the card

```bash
gpg --homedir "$YKHOME" --card-status
```

If you get:

```text
gpg: selecting card failed: No such device
```

check `$YKHOME/scdaemon.conf` and restart:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

> **macOS:** also kill the default-home scdaemon (`gpgconf --kill scdaemon`) and check that `~/.gnupg/scdaemon.conf` exists (step 2).

## 8. Move the primary `[SC]` into the Signature slot

Example fingerprint:

```text
7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

```bash
gpg --homedir "$YKHOME" --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Inside:

```text
keytocard
```

Confirm moving the primary key and choose:

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

## 9. Move the encryption subkey `[E]`

Open the key again:

```bash
gpg --homedir "$YKHOME" --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Select the encryption subkey:

```text
key 1
```

Make sure the `*` is on the subkey with usage `[E]`.

Then:

```text
keytocard
```

Choose:

```text
2 = Encryption key
```

and:

```text
save
```

## 10. Enable touch policy

```bash
ykman openpgp keys set-touch SIG fixed
ykman openpgp keys set-touch ENC fixed
```

`ykman` asks for the Admin PIN, at this point still `12345678`. `fixed` cannot be turned off without deleting the key from the slot.

Check:

```bash
ykman openpgp info
gpg --card-status
```

Expected:

```text
Touch policies: Signature key: On (fixed), Encryption key: On (fixed)
UIF setting ......: Sign=permanent Decrypt=permanent Auth=off
```

## 11. Check the card state

Preferably via the same temporary GNUPGHOME:

```bash
gpg --homedir "$YKHOME" --card-status
```

Example:

```text
Serial number ....: 12345678
Key attributes ...: rsa4096 rsa4096 rsa4096
PIN retry counter : 3 0 3
KDF setting ......: on
UIF setting ......: Sign=permanent Decrypt=permanent Auth=off

Signature key ....: ...
Encryption key....: ...

sec> ... card-no: 0006 12345678
ssb> ... card-no: 0006 12345678
```

## 12. Functional test before the final PIN change

Signing:

```bash
date > /tmp/pgp-test.txt

gpg --homedir "$YKHOME" --detach-sign /tmp/pgp-test.txt
```

Decryption:

```bash
echo "decrypt test" > /tmp/pgp-plain.txt

gpg --homedir "$YKHOME" --recipient 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901 --encrypt /tmp/pgp-plain.txt

gpg --homedir "$YKHOME" --decrypt /tmp/pgp-plain.txt.gpg
```

Both operations must work and require touch.

## 13. Only now change the User PIN

```bash
gpg --card-edit
```

Inside:

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

## 14. Then change the Admin PIN

In the same menu:

```text
3
```

Current Admin PIN:

```text
12345678
```

Set a separate long Admin PIN.

Important: the Admin PIN cannot be recovered via the Reset Code. If the Admin PIN gets blocked, the OpenPGP applet has to be reset and the keys moved again from the backup.

## 15. Reset Code - optional

Can be set via:

```text
gpg --card-edit
admin
passwd
4
```

But it is only needed to recover the User PIN.

It:

```text
does NOT recover the Admin PIN
is NOT required
```

Normal state without a Reset Code:

```text
PIN retry counter : 3 0 3
```

## 16. Final check

```bash
gpg --card-status
```

Expected:

```text
PIN retry counter : 3 0 3
KDF setting ......: on
UIF setting ......: Sign=permanent Decrypt=permanent Auth=off
```

Check signing and decryption once more, now with the final User PIN.

## 17. Switch the live `~/.gnupg` to card stubs

The live `~/.gnupg` still holds the private keys on disk. Replace them with card stubs.

Stop the temporary home and the live agent:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
gpgconf --kill gpg-agent
```

Get the keygrips of the `sec [SC]` key and the `ssb [E]` subkey:

```bash
gpg --list-secret-keys --with-keygrip --keyid-format LONG 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Delete exactly these two private key files:

```bash
rm -i "$HOME/.gnupg/private-keys-v1.d/<KEYGRIP_SC>.key" \
      "$HOME/.gnupg/private-keys-v1.d/<KEYGRIP_E>.key"
```

Recreate the stubs from the card:

```bash
gpg --card-status
```

If the stubs do not appear:

```bash
gpg-connect-agent "scd serialno" "learn --force" /bye
```

Check:

```bash
gpg --list-secret-keys --keyid-format LONG 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Expected:

```text
sec> ... [SC]  card-no: 0006 12345678
ssb> ... [E]   card-no: 0006 12345678
```

Repeat a sign and decrypt test with the live home.

## 18. Encrypt the original backup

Encrypt the original pre-YubiKey backup both symmetrically (passphrase) and to the key itself, so either one can decrypt it:

```bash
gpg --symmetric --encrypt \
    --recipient 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901 \
    --cipher-algo AES256 \
    --s2k-digest-algo SHA512 --s2k-count 65011712 \
    --pinentry-mode loopback \
    --output "$HOME/gnupg-backup-$(date -u +%Y%m%d).tar.gz.gpg" \
    "$YKRAM/gnupg-backup.tar.gz"
```

Use a long passphrase, separate from both PINs, and store it separately from the encrypted file.

Test the key path (requires PIN and touch):

```bash
gpg --decrypt "$HOME/gnupg-backup-$(date -u +%Y%m%d).tar.gz.gpg" | tar -tzf - >/dev/null && echo OK
```

Test the passphrase path (empty home without the secret key, so gpg must use the passphrase):

```bash
mkdir -m 700 "$YKRAM/symtest"
gpg --homedir "$YKRAM/symtest" --pinentry-mode loopback \
    --decrypt "$HOME/gnupg-backup-$(date -u +%Y%m%d).tar.gz.gpg" | tar -tzf - >/dev/null && echo OK
gpgconf --homedir "$YKRAM/symtest" --kill gpg-agent
```

Move the encrypted backup to its long-term storage off the laptop: personal Google Drive or as a file attachment in 1Password.

> **macOS:** the plaintext backup lives only on the RAM disk and disappears with it in step 19. Do not copy it anywhere else; on APFS/SSD a deleted file cannot be reliably overwritten.

## 19. Cleanup

After successful tests:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
rm -f /tmp/pgp-test.txt /tmp/pgp-test.txt.sig /tmp/pgp-plain.txt /tmp/pgp-plain.txt.gpg
hdiutil detach "$YKRAM"
```

> **macOS:** `hdiutil detach` destroys the RAM disk with the temporary keyring and the plaintext backup; `rm -rf "$YKHOME"` alone is not enough.

## 20. For a second/third YubiKey

Repeat the process **again from the original pre-YubiKey backup**, not from the temporary keyring, which has already turned into card stubs.

> **macOS:** create a new RAM disk (step 0) and decrypt the encrypted backup onto it instead of step 1:
>
> ```bash
> gpg --output "$YKRAM/gnupg-backup.tar.gz" --decrypt <encrypted-backup>.tar.gz.gpg
> ```

Working order:

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

## Short checklist

```text
[ ] RAM disk created, Spotlight indexing off (macOS)
[ ] original backup written to the RAM disk
[ ] YubiKey serial checked
[ ] OpenPGP reset done if needed
[ ] RSA4096 attributes set
[ ] KDF enabled
[ ] temporary GNUPGHOME sees the card
[ ] primary [SC] moved to the Signature slot
[ ] encryption [E] moved to the Encryption slot
[ ] touch SIG fixed
[ ] touch ENC fixed
[ ] sign test works
[ ] decrypt test works
[ ] User PIN changed to the final one
[ ] Admin PIN changed to the final one
[ ] PIN retry counter = 3 0 3
[ ] KDF = on
[ ] UIF = Sign=permanent Decrypt=permanent Auth=off
[ ] live ~/.gnupg shows sec> / ssb> (card stubs)
[ ] original backup encrypted (passphrase + key), both decrypt paths tested
[ ] encrypted backup moved off the laptop
[ ] RAM disk detached
```
