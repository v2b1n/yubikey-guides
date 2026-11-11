# YubiKey OpenPGP Setup on macOS

This guide sets up an OpenPGP key for use with GnuPG on macOS and a YubiKey 5 Series. It covers local key creation, transfer to the YubiKey, PIN setup, touch policy, and checks.

The key is created on the Mac first. This keeps an exportable master backup available before you transfer private key material to the YubiKey. To move an existing key, use the [macOS OpenPGP migration guide](migration/yubikey-openpgp-key-migration-howto-macOS-EN.md).

> **Scope:** This guide covers the OpenPGP application only. The OpenPGP User PIN and Admin PIN are separate from PIV PINs, PUKs, and Management Keys.

## 1. Install and check the software

Use one GnuPG installation for `gpg`, `gpg-agent`, `scdaemon`, and Pinentry. This example uses Homebrew:

```bash
brew install gnupg pinentry-mac yubikey-manager
command -v gpg ykman
gpg --version
ykman --version
ykman info
```

Confirm that macOS detects the YubiKey. Check the serial number before you make changes.

Create the GnuPG configuration directory and set its permissions:

```bash
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg
```

Configure GnuPG to use macOS PC/SC if `scdaemon` and `ykman` compete for the YubiKey:

```bash
cat > ~/.gnupg/scdaemon.conf <<'EOF'
disable-ccid
pcsc-shared
EOF
chmod 600 ~/.gnupg/scdaemon.conf
gpgconf --kill scdaemon
```

Check that GnuPG can read the card:

```bash
gpg --card-status
```

If this command fails, check the GnuPG installation and PC/SC configuration before you continue.

If Pinentry displays a **Save in Keychain** option, leave it unchecked for PIN and passphrase prompts.

## 2. Create a local OpenPGP key

Create a new key on the Mac:

```bash
gpg --full-generate-key
```

Follow the prompts. Select a key type and size supported by your YubiKey firmware and GnuPG version. Set an expiration date. Enter the user's name and email address. Set a strong passphrase.

Record the primary key fingerprint:

```bash
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint
```

Set a shell variable to the full primary fingerprint. Replace the example value:

```bash
FPR='REPLACE_WITH_PRIMARY_FINGERPRINT'
```

Confirm that the fingerprint is correct:

```bash
gpg --fingerprint "$FPR"
```

## 3. Make and verify a full backup

Make a backup before you transfer any private key to the YubiKey. The backup must include the secret key material. Protect it with strong encryption and store it offline.

Export the secret key to an encrypted OpenPGP file:

```bash
gpg --armor --output "$FPR-secret-backup.asc" --export-secret-keys "$FPR"
```

The export uses the protection on the secret key. Confirm that the key has a strong passphrase before you create the backup. Store the file on encrypted offline storage. Do not leave an unprotected copy in Downloads, cloud storage, or a shared folder.

Export the public key separately:

```bash
gpg --armor --output "$FPR-public.asc" --export "$FPR"
```

Verify the files and record their checksums:

```bash
ls -l "$FPR-secret-backup.asc" "$FPR-public.asc"
shasum -a 256 "$FPR-secret-backup.asc" "$FPR-public.asc"
```

Keep the secret backup available until you have tested the YubiKey and verified a second offline backup. The card stubs shown by GnuPG after transfer are not a backup of the private keys.

## 4. Prepare the YubiKey OpenPGP application

Check the token again:

```bash
ykman info
ykman openpgp info
```

If you must erase the OpenPGP application, verify the serial number first. A reset deletes OpenPGP keys and settings on that YubiKey:

```bash
ykman openpgp reset
```

This reset does not reset the PIV, FIDO, OATH, or OTP applications.

After a reset, the factory PINs are:

```text
User PIN:  123456
Admin PIN: 12345678
```

Do not leave factory PINs in place for normal use.

Enable the OpenPGP KDF before you transfer keys. Start the interactive card editor:

```bash
gpg --card-edit
```

At the prompt, enter these commands:

```text
admin
kdf-setup
quit
```

Follow the prompts. With a newly reset card, enter the factory User PIN and Admin PIN when requested. Verify the KDF state:

```bash
gpg --card-status
```

Confirm that the card reports KDF enabled before you continue.

## 5. Transfer the secret keys to the YubiKey

The transfer removes the selected private key material from the local GnuPG keyring and places it in the YubiKey. GnuPG keeps card stubs in the keyring. Keep the verified secret backup from section 3.

Start the key editor:

```bash
gpg --edit-key "$FPR"
```

At the prompt, select each key that you will transfer, one at a time. The primary key normally provides signing and certification. The encryption subkey provides decryption.

The primary key is selected when the editor opens. Confirm that it is the primary signing and certification key, then use:

```text
keytocard
```

Choose **Signature key** when GnuPG asks for a card slot. Enter `save` to finish.

Transfer the encryption subkey in a separate editor session:

```bash
gpg --edit-key "$FPR"
```

At the prompt, select the encryption subkey. For a key with one subkey, enter `key 1`. Confirm that the asterisk (`*`) is on the subkey marked `[E]`. Then enter:

```text
keytocard
```

Choose **Encryption key** when GnuPG asks for a card slot. Enter `save` to finish. GnuPG may ask for the key passphrase and card PIN. Use the **Authentication key** slot only if you have a separate OpenPGP authentication subkey and a defined use for it.

Check the card and local keyring:

```bash
gpg --card-status
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint
```

The transferred keys should show as card-backed stubs (a `>` marker in the secret-key listing). Confirm that the displayed fingerprints match the values recorded before transfer.

## 6. Set PINs and touch policy

Change the User PIN and Admin PIN in the card editor:

```bash
gpg --card-edit
```

At the prompt, enter:

```text
admin
passwd
```

Follow the prompts to change both PINs. Store the Admin PIN in secure recovery storage. Do not store the User PIN in the macOS Keychain as part of this setup. Do not guess PINs: the card limits retry attempts.

Set a fixed touch policy for the signing and encryption keys:

```bash
ykman openpgp keys set-touch sig fixed
ykman openpgp keys set-touch enc fixed
ykman openpgp info
gpg --card-status
```

If your `ykman` version does not accept `enc`, check its help and use the encryption slot name it lists, often `dec`:

```bash
ykman openpgp keys set-touch --help
```

A `fixed` policy requires a physical touch for each applicable operation. You cannot relax this policy for the existing key. Replace the key material to use a different policy. Set `aut fixed` only if you also use the authentication slot.

## 7. Test signing and decryption

Create and sign a test file:

```bash
printf 'YubiKey OpenPGP test\n' > /tmp/yubikey-openpgp-test.txt
gpg --detach-sign /tmp/yubikey-openpgp-test.txt
gpg --verify /tmp/yubikey-openpgp-test.txt.sig /tmp/yubikey-openpgp-test.txt
```

The signing operation must request a YubiKey touch when the fixed policy is active.

Encrypt the test file to your own key and decrypt it:

```bash
gpg --recipient "$FPR" --encrypt /tmp/yubikey-openpgp-test.txt
gpg --output /tmp/yubikey-openpgp-test.dec.txt --decrypt /tmp/yubikey-openpgp-test.txt.gpg
cmp /tmp/yubikey-openpgp-test.txt /tmp/yubikey-openpgp-test.dec.txt
```

The decryption operation must request a YubiKey touch when the fixed policy is active. `cmp` must return no output and exit with status 0.

Remove the test files:

```bash
rm -f /tmp/yubikey-openpgp-test.txt /tmp/yubikey-openpgp-test.txt.sig \
  /tmp/yubikey-openpgp-test.txt.gpg /tmp/yubikey-openpgp-test.dec.txt
```

## 8. Export and publish the public key

Export the public key at any time:

```bash
gpg --armor --output "$FPR-public.asc" --export "$FPR"
```

Verify the fingerprint before you publish the key:

```bash
gpg --show-keys --with-fingerprint "$FPR-public.asc"
```

Share the public key through the required directory or service. Keep the private-key backup private and offline.

## 9. Recovery notes

- Keep at least one verified, encrypted offline backup of the secret keys.
- Keep the Admin PIN and recovery data in secure storage separate from the YubiKey.
- Do not treat a YubiKey as the only copy of an identity.
- If you lose the token, use the offline backup to provision a replacement token or revoke the affected key and publish a replacement.
- For a detailed macOS procedure to move an existing key, including RAM-disk handling and verification, follow the [OpenPGP key migration guide](migration/yubikey-openpgp-key-migration-howto-macOS-EN.md).
