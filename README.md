# YubiKey & Yubico Security Key — Hardware-backed SSH and OpenPGP

Practical, security-conscious setup guides for hardware-backed SSH access and Git signing on macOS and Debian.

## Which key and guide?

| Hardware / goal | Guide |
| --- | --- |
| **Security Key by Yubico**, macOS — FIDO2 `ed25519-sk`, SSH and Git SSH signing | [Security Key / macOS](yubico-security-key-ssh-macos.md) |
| **YubiKey 5**, macOS — PIV-based SSH and optional OpenPGP signing/decryption | [YubiKey 5 / macOS](yubikey-piv-ssh-and-openpgp-macos.md) |
| **YubiKey 5**, Debian — PIV SSH plus OpenPGP interaction and PC/SC recovery | [YubiKey 5 / Debian](yubikey-piv-ssh-and-gpg-setup-debian.md) |
| **YubiKey 5**, macOS — short PIV provisioning and checks | [Quick reference](yubikey-piv-ssh-macos-quick-reference.md) |
| **YubiKey 5**, macOS — interactive PIV key provisioning | [Provisioning script](provision-yubikey-piv.sh) |
| Existing RSA SSH key or OpenPGP keys — move them onto a YubiKey | [Migration guides](migration/) |

## Security Key or YubiKey 5?

**Security Key by Yubico** is a straightforward choice for modern SSH and Git using FIDO2. SSH uses a FIDO-specific `sk-ssh-ed25519@openssh.com` public key, and the local resident-credential handle should be protected with a passphrase. The linked macOS guide explains 12-hour `ssh-agent` caching and the optional `verify-required` trade-off.

**YubiKey 5** adds **PIV** and **OpenPGP** applications. PIV permits ordinary, non-FIDO SSH key formats such as RSA or, with compatible device/provider versions, Ed25519; it can **generate a new non-exportable private key** or **import a compatible existing private key**. Importing allows continuity of an existing SSH identity or provisioning multiple tokens with the same key, but the original secret key and its backup become additional sensitive assets. OpenPGP has separate signing/encryption keys, allowing **SSH/PIV for access** and **OpenPGP for Git/email signing**.

These are alternative architectures, not interchangeable commands. In particular, hardware PIV Ed25519 capability does **not** automatically guarantee OpenSSH/PKCS#11 interoperability on a particular macOS build: perform the compatibility and end-to-end signing tests in the guides before relying on it.

## Migration references

- [OpenPGP migration on macOS (English)](migration/yubikey-openpgp-key-migration-howto-macOS-EN.md)
- [OpenPGP migration on Debian (English)](migration/yubikey-openpgp-key-migration-howto-debian-EN.md) · [Русский](migration/yubikey-openpgp-key-migration-howto-debian-RU.md)
- [PIV SSH key migration on Debian (English)](migration/yubikey-piv-ssh-key-migration-howto-debian-EN.md) · [Русский](migration/yubikey-piv-ssh-key-migration-howto-debian-RU.md)

**Do not reset a YubiKey or import a private key without an appropriate backup.** Keep PIV recovery secrets and any provisioning records out of public repositories. The included provisioning script writes sensitive recovery material to a local, permission-restricted **plaintext** file; move it to secure encrypted storage and remove the plaintext copy. A `.gitignore` entry helps prevent accidental inclusion of these records, but is not a substitute for protecting them.

## License

MIT — see [LICENSE](LICENSE). Contributions and fixes are welcome.
