# YubiKey PIV for SSH and Git signing on macOS

**Self-service PIV setup — short reference (see the [full macOS guide](yubikey-piv-ssh-and-openpgp-macos.md))**  
**Hardware:** YubiKey 5 Series, firmware 5.7+  
**Target:** macOS / Apple Silicon  
**PIV identity:** slot `9a`, Ed25519, `PIN policy = ONCE`, `touch policy = ALWAYS`



## 1. Purpose and security invariant

> Every cryptographic signing operation must require physical human presence, enforced by immutable hardware key policy. Access to the key additionally requires possession of the YubiKey and authentication with the user's personal PIN.

The primary threat is **silent SSH authentication or Git commit signing by malware, a compromised local environment, or automated software running under the account**. Such software could attempt to authenticate to servers or GitHub, sign malicious code, and push it without the user noticing.

**Security invariant:** every new private-key signature must require physical human interaction with the YubiKey. An automated process must not be able to perform such signatures silently or disable the touch requirement through client configuration.

The private key is generated inside the YubiKey's **PIV** application and remains non-exportable. At key generation, the token owner sets:

- `PIN policy = ONCE`: PIN verification once per PIV authentication session.
- `touch policy = ALWAYS`: a physical touch for **each private-key operation**.

Both policies are stored with the PIV private key and **cannot be changed for that existing key**. Replacing the key requires PIV administrative access with the **Management Key**. Keep the PIV Management Key and PUK in secure storage, and choose a personal PIN. Record the public-key fingerprint for later verification. Physical touch establishes user presence, rather than proof that the human inspected the particular operation.

The same PIV-backed SSH identity is used for **SSH authentication** and **Git SSH commit signing**.

Official policy documentation: https://docs.yubico.com/yesdk/users-manual/application-piv/pin-touch-policies.html

## 2. Install Yubico tools on macOS

Install the official **Yubico PIV Tool** macOS universal package and **YubiKey Manager CLI (`ykman`)**. The PIV Tool includes the `libykcs11.dylib` PKCS#11 provider.

Locate the provider and confirm `ykman`:

```bash
command -v ykman
find /usr/local /opt/homebrew -name libykcs11.dylib 2>/dev/null
```

Use the actual provider location in the commands below (normally `/usr/local/lib/libykcs11.dylib` for the official package):

```bash
PROVIDER=/usr/local/lib/libykcs11.dylib
test -r "$PROVIDER"
```

Reference: https://users.yubico.com/PIV/Guides/SSH_with_PIV_and_PKCS11.html

## 3. Provision your YubiKey

Check your YubiKey serial number and firmware, and choose an email address for the public-key comment:

```bash
ykman info
EMAIL='user@example.com'
PUBTMP="$(mktemp /tmp/yubikey-9a-public.XXXXXX.pem)"
```

Set PIV retry limits **before changing the default PIN/PUK**. This command resets both to their factory values (`123456` / `12345678`):

```bash
# PIN: 10 attempts; PUK: 5 attempts.
ykman piv access set-retries 10 5
```

Set recovery and management credentials, and store both securely:

```bash
# Default PUK: 12345678; length: 6–8 characters; 5 attempts.
ykman piv access change-puk

# Prints the generated AES-192 Management Key as a hex string.
ykman piv access change-management-key --algorithm AES192 --generate
```

Keep the new **PUK** and **Management Key** in secure recovery storage, separate from the token and personal PIN.

Generate the private key **inside PIV slot `9a`** with immutable policies:

```bash
ykman piv keys generate \
  --algorithm ED25519 \
  --pin-policy ONCE \
  --touch-policy ALWAYS \
  9a "$PUBTMP"
```

Create the corresponding PIV certificate (required for PKCS#11 public-key discovery):

```bash
ykman piv certificates generate \
  --subject "CN=${EMAIL}" \
  --valid-days 3650 \
  9a "$PUBTMP"
```

Confirm the on-device key and policies:

```bash
ykman piv keys info 9a
```

Required output: **Ed25519**, **PIN policy Once**, **Touch policy Always**, key generated on-chip.

Export the public SSH key and record its fingerprint:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -D "$PROVIDER" \
  | awk -v email="$EMAIL" '$1 == "ssh-ed25519" {print $1, $2, email; exit}' \
  | tee ~/.ssh/id_ed25519.pub
ssh-keygen -lf ~/.ssh/id_ed25519.pub
rm -f "$PUBTMP"
```

**Compatibility acceptance gate:** `ssh-keygen -D "$PROVIDER"` must actually expose the enrolled **Ed25519** key, and an end-to-end SSH authentication **and** Git SSH signature must succeed on the target macOS/OpenSSH build. PIV Ed25519 availability on firmware 5.7+ alone does **not** prove YKCS11/OpenSSH compatibility. Validate this before relying on this configuration. If the gate fails, resolve the client/provider compatibility or choose a compatible alternate PIV algorithm under the same two hardware policies.

Related Yubico compatibility report: https://github.com/Yubico/yubico-piv-tool/issues/507

Change your PIV PIN (or ask the new owner to do it during an optional handover):

```bash
# Default pin: 123456
# Length: 6–8 characters, A–Z/a–z/0–9 supported.
# 10 failed attempts, then the PIN is blocked.
# A holder of the PUK can unblock the PIN.
ykman piv access change-pin

```

Record the **SSH public-key fingerprint** and YubiKey serial for your own reference. If the token is handed to someone else, let that person set their final PIN.

## 4. Load PIV identity into the macOS ssh-agent

Use the existing macOS session agent:

```bash
ssh-add -t 12h -s "$PROVIDER"
ssh-add -l
```

The user enters their **PIV PIN** on loading. For subsequent signatures, the YubiKey enforces **touch on every operation**. The `12h` setting is the identity's maximum agent lifetime; PIV PIN verification is scoped to the token's authenticated card session and may need repeating after removal, reconnection, or session reset.

## 5. Configure SSH and Git

Configure `~/.ssh/config`:

```sshconfig
Host *
  IdentityFile ~/.ssh/id_ed25519.pub
  IdentitiesOnly yes
  ForwardAgent no
  ForwardX11 no
  ControlMaster no
```

`ControlMaster no` ensures each **new SSH connection** performs fresh authentication rather than using an existing multiplexed connection. An already authenticated SSH connection may still carry multiple operations; touch is tied to **cryptographic signatures**, not to every Git command or network packet.

Configure Git SSH transport and commit signing:

```bash
git config --global gpg.format ssh
git config --global user.signingkey "$HOME/.ssh/id_ed25519.pub"
git config --global commit.gpgsign true
```

Register `~/.ssh/id_ed25519.pub` on GitHub separately as **Authentication Key** and **Signing Key** (if both purposes are used).

Test SSH and Git signing with the identity loaded:

```bash
ssh -T git@github.com
ssh-keygen -lf ~/.ssh/id_ed25519.pub
git commit --allow-empty -m 'hardware-signing-test'
```

Each new SSH authentication signature and each Git commit signature must prompt for physical touch. For the test commit, use a disposable test repository with `user.name` and `user.email` set.

## 6. Local verification

Install the Yubico PIV Tool and `ykman` locally, provision the token interactively, and keep recovery credentials out of your repository.

After setup and periodically thereafter, check:

```bash
ykman piv keys info 9a
ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub"
ssh -G github.com | grep -i '^controlmaster '
git config --global --get gpg.format
git config --global --get user.signingkey
git config --global --get commit.gpgsign
```

**Required:** `PIN Once`, `Touch Always`, `ControlMaster no`, SSH signing enabled; SSH public-key fingerprint matches the public key you registered.

Optionally enable signed-commit requirements in your GitHub repository settings. If you replace a key, update the corresponding registered public key(s) and remove any key you no longer trust.

## 7. Provisioning checklist

- [ ] YubiKey serial and firmware checked; firmware 5.7+
- [ ] PIN retry limit 10 / PUK retry limit 5 verified; PUK and Management Key securely stored
- [ ] PIV `9a` key generated on-device; `PIN ONCE`, `TOUCH ALWAYS` verified
- [ ] PIV certificate created; `libykcs11` exposes the intended public key
- [ ] Public SSH key exported; fingerprint recorded for reference
- [ ] Personal PIV PIN set
- [ ] SSH authentication and Git SSH commit signing tested with touch
- [ ] SSH/Git configuration verified and public key registered





## Reference docs 

* ykman piv commands https://docs.yubico.com/software/yubikey/tools/ykman/PIV_Commands.html
