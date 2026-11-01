# YubiKey PIV for SSH and Git signing on macOS — Personal Setup


> **Why choose a full YubiKey 5 instead of a FIDO-only Security Key?** PIV supports standard SSH key types (including RSA, ECDSA and, on supported firmware/tooling, Ed25519) instead of requiring `sk-*` keys. A compatible existing SSH private key can be **imported** into PIV, or a new private key can be **generated on the device**. Imported key material also exists outside the token and must remain securely backed up or destroyed as appropriate. A separate **OpenPGP application** can hold signing and encryption keys at the same time: for example, use PIV for SSH access and OpenPGP for Git/email signing. See [the OpenPGP section](#20-openpgp-on-the-same-yubikey-for-signing-and-encryption) and the [migration guides](migration/).

> **Hardware:** YubiKey 5 Series (not the FIDO-only Security Key by Yubico). This SSH example uses PIV slot `9a`, Ed25519, `PIN ONCE`, and `touch ALWAYS`. **Verify client-side PKCS#11/Ed25519 support before relying on this variant**; see §3 and the acceptance test.




> Target: macOS (Apple Silicon; the PIV/PKCS#11 procedure also applies to compatible Intel Macs).
>
> Suggested security setup:
>
> - one **Ed25519 key is generated on-device inside the YubiKey PIV application**;
> - PIV slot `9a` is used;
> - the private key is never exported and never exists as a normal file;
> - `PIN policy = ONCE`;
> - `touch policy = ALWAYS`;
> - the same standard SSH key can be used for SSH authentication and Git SSH commit signing;
> - the exported public key is the normal OpenSSH form `ssh-ed25519 ... user@example.com`, **not** a FIDO `sk-ssh-ed25519@openssh.com` credential;
> - the PIV Management Key and PUK remain under owner control;
> - use a personal PIN;
> - every actual private-key signature requires physical YubiKey touch;
> - SSH connection multiplexing is disabled so Git/SSH operations cannot silently reuse an already authenticated connection.

## 1. Supported software

Use a macOS release supported by the installed OpenSSH, GnuPG, and Yubico software; verify the versions on your machine.

Yubico officially supports using the PIV application with OpenSSH through its YKCS11 PKCS#11 module on macOS.

Install the official Yubico `yubico-piv-tool` macOS package or use Homebrew. The official universal package is convenient when matching both Apple Silicon and Intel Macs.

Yubico PIV Tool version referenced by the original procedure (verify the installed/current release yourself):

```text
yubico-piv-tool 2.7.3
```

Official macOS packages are provided for:

```text
arm64
amd64
universal
```

The universal package can be used on both Apple Silicon and Intel.

References:

- https://users.yubico.com/PIV/Guides/SSH_with_PIV_and_PKCS11.html
- https://users.yubico.com/yubico-piv-tool/Releases/
- https://docs.yubico.com/software/yubikey/tools/pivtool/piv-tool-ykcs11.html

## 2. Install Yubico PIV Tool

### Official package installation

Install the official Yubico universal `.pkg` on macOS.

After installation, verify:

```bash
which yubico-piv-tool
```

and locate the PKCS#11 library:

```bash
find /usr/local /opt/homebrew \
  -name 'libykcs11.dylib' \
  2>/dev/null
```

With the official Yubico installer the expected location is normally:

```text
/usr/local/lib/libykcs11.dylib
```

### Homebrew alternative

Alternatively, with Homebrew:

```bash
brew install yubico-piv-tool
```

On Apple Silicon the library may then be exposed below the Homebrew prefix:

```text
/opt/homebrew/lib/libykcs11.dylib
```

Choose the actual provider path reported by `find` rather than assuming a fixed Homebrew prefix.

## 3. Provision your YubiKey

Perform these steps interactively on your own YubiKey. For an optional handover to another person, see §12.

### 3.1 Requirements and algorithm

Use a YubiKey 5 Series with firmware **5.7 or later**. Ed25519 support in the PIV application requires firmware 5.7+.

Verify:

```bash
ykman info
```

The example key is generated in PIV slot `9a` with:

```text
Algorithm:     Ed25519
PIN policy:    ONCE
Touch policy:  ALWAYS
```

This is a normal PIV/PKCS#11 Ed25519 key. It is **not** the FIDO/OpenSSH security-key type `sk-ssh-ed25519@openssh.com`.

The public key ultimately registered in GitHub/servers is the ordinary OpenSSH form:

```text
ssh-ed25519 AAAA... user@example.com
```

so the remote SSH server does not need YubiKey or FIDO support.

If a specific legacy client/provider on your machine cannot consume Ed25519 through PKCS#11, use `ECCP256` as the fallback algorithm; do not switch to an `*-sk` FIDO key merely for compatibility.

### 3.2 Set recovery PUK and Management Key

Do not leave factory PIN, PUK, or Management Key values on a token used for real authentication.

Change the PUK interactively and store the new value securely, separately from the device:

```bash
ykman piv access change-puk
```

Then replace the factory PIV Management Key with a random Management Key:

```bash
ykman piv access change-management-key --algorithm AES192 --generate
```

**Record the generated Management Key immediately in secure storage.** This recipe deliberately does not use `--protect`: with `--protect`, the Management Key is stored on the YubiKey protected by the PIN. That is a different recovery/administration trade-off; choose it consciously, rather than implicitly.

Important distinction:

```text
PIN
  → normal private-key use
  → changed by the token owner

PUK
  → unblocks/resets a blocked PIN
  → kept in secure recovery storage

Management Key
  → administrative PIV operations, including generating/replacing keys
  → kept in secure recovery storage
```

The **Management Key**, not the PUK, authorizes key replacement and can therefore enable a replacement key with a different touch policy. Protect it accordingly.

`touch-policy ALWAYS` is set when the private key is generated. It cannot be changed in-place for that key; changing the policy requires replacing/regenerating the key, which is an administrative operation protected by the Management Key.

### 3.3 Set your personal PIN

Change the default or temporary PIN to a personal PIN:

```bash
ykman piv access change-pin
```

Do not store the personal PIN in plaintext alongside the YubiKey or a provisioning record.

For maximum compatibility, keep the PIN within the YubiKey PIV limits (6-8 alphanumeric characters). Numeric PINs have the widest cross-platform compatibility, but an alphanumeric PIN is supported by YubiKey PIV itself.

### 3.4 Generate the Ed25519 private key inside the YubiKey

Set the user email and create a temporary public-key file:

```bash
EMAIL="user@example.com"
PUBTMP="/tmp/yubikey-9a-ed25519-public.pem"
```

Generate the key **on-device** in PIV slot `9a`:

```bash
ykman piv keys generate \
  --algorithm ED25519 \
  --pin-policy ONCE \
  --touch-policy ALWAYS \
  9a "$PUBTMP"
```

The private key is generated by the YubiKey and never leaves the token. For the **import** alternative, see the dedicated PIV SSH migration guide; an imported private key is only as protected as any surviving offline/software copies.

Verify the key metadata:

```bash
ykman piv keys info 9a
```

The result must show an Ed25519 key generated on-chip with:

```text
PIN policy:   Once
Touch policy: Always
```

### 3.5 Create the PIV certificate

YKCS11 exposes the PIV public-key object through the X.509 certificate stored in the slot, so create a self-signed certificate for slot `9a`.

This example uses an email address as the certificate common name:

```bash
ykman piv certificates generate \
  --subject "CN=${EMAIL}" \
  --valid-days 3650 \
  9a "$PUBTMP"
```

This certificate is only the container/metadata needed for PIV/PKCS#11 use; SSH trust is still based on the SSH public key registered in GitHub or on the target server.

### 3.6 Export directly to the standard OpenSSH public-key path

Create the user's SSH directory:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
```

Locate YKCS11:

```bash
if [ -f /usr/local/lib/libykcs11.dylib ]; then
  PROVIDER=/usr/local/lib/libykcs11.dylib
else
  PROVIDER=/opt/homebrew/lib/libykcs11.dylib
fi
```

Export the public key in native OpenSSH format and add the user email as the SSH key comment:

```bash
ssh-keygen -D "$PROVIDER" \
  | awk -v email="$EMAIL" 'NR==1 { print $1, $2, email }' \
  | tee ~/.ssh/id_ed25519.pub
```

Set permissions:

```bash
chmod 600 ~/.ssh/id_ed25519.pub
```

Verify:

```bash
cat ~/.ssh/id_ed25519.pub
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

Expected form:

```text
ssh-ed25519 AAAA... user@example.com
```

There must be **no** local private-key file:

```text
~/.ssh/id_ed25519
```

Only this public file is expected:

```text
~/.ssh/id_ed25519.pub
```

Remove the temporary PEM public key after provisioning:

```bash
rm -f "$PUBTMP"
```

### Disable unused Yubico OTP over USB

If Yubico OTP is not used in the intended setup, disable it on the USB transport:

```bash
ykman config usb --disable OTP
```

`ykman` will show the pending USB configuration change and ask for confirmation. The YubiKey reboots after the change.

Verify with:

```bash
ykman info
```

Expected USB state:

```text
Enabled USB interfaces: FIDO, CCID

Applications    USB
Yubico OTP      Disabled
FIDO U2F        Enabled
FIDO2           Enabled
OATH            Enabled
PIV             Enabled
OpenPGP         Enabled
YubiHSM Auth    Enabled
```

This only disables the Yubico OTP application on the **USB transport**. It does not disable FIDO, PIV, OpenPGP, OATH, or YubiHSM Auth, and it does not change the NFC configuration. If OTP is also unnecessary over NFC, that can be disabled separately.


## 4. Verify the exported SSH public key

The provisioning step already writes the public key to the standard path:

```text
~/.ssh/id_ed25519.pub
```

Verify that it is a plain Ed25519 SSH key and contains the user email comment:

```bash
cat ~/.ssh/id_ed25519.pub
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

Expected prefix:

```text
ssh-ed25519
```

It must **not** be:

```text
sk-ssh-ed25519@openssh.com
```

The latter is a FIDO/OpenSSH security-key credential and has different server/client compatibility characteristics.

## 5. Verify PKCS#11 access directly

First locate the provider:

```bash
PROVIDER=/usr/local/lib/libykcs11.dylib
```

If using Homebrew on Apple Silicon:

```bash
PROVIDER=/opt/homebrew/lib/libykcs11.dylib
```

Test that OpenSSH can see the PIV key:

```bash
ssh-keygen -D "$PROVIDER" \
  | head -1 \
  | ssh-keygen -lf -
```

The fingerprint must match:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

## 6. ssh-agent on macOS

macOS normally provides an SSH agent for the logged-in graphical user through the system session.

Check:

```bash
echo "$SSH_AUTH_SOCK"
ssh-add -L
```

If the output is:

```text
The agent has no identities.
```

the agent is available and simply has no loaded identities.

Do **not** normally start a second `ssh-agent` manually on a Mac.

Only for troubleshooting in an isolated shell, if no agent socket exists at all:

```bash
eval "$(ssh-agent -s)"
```

## 7. Load the YubiKey into ssh-agent for 12 hours

With the official Yubico package:

```bash
ssh-add \
  -t 12h \
  -s /usr/local/lib/libykcs11.dylib
```

This asks for the PIV PIN.

After successful loading:

```bash
ssh-add -l
ssh-add -L
```

The important security behavior is:

```text
PIN policy ONCE
+
ssh-agent keeps the PKCS#11 identity loaded
+
touch policy ALWAYS
```

Result:

```text
First operation:
  PIN
  touch

Next operations during the 12-hour agent lifetime:
  touch only
```

The `12h` value is a fixed lifetime from the moment the identity is added to `ssh-agent`.

It is **not** an idle timeout and Git/SSH activity does not extend it.

Remove the provider manually:

```bash
ssh-add -e /usr/local/lib/libykcs11.dylib
```

## 8. SSH configuration

Recommended user configuration in:

```text
~/.ssh/config
```

Example:

```sshconfig
Host *
  ServerAliveInterval 30

  ForwardX11 no
  ForwardAgent no

  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519.pub

  # Required if every new SSH/Git connection must perform
  # a fresh hardware-backed signature.
  ControlMaster no
```

### Do not configure PKCS11Provider here

When using the `ssh-agent` model, do **not** add:

```sshconfig
PKCS11Provider /usr/local/lib/libykcs11.dylib
```

The PKCS#11 provider is loaded into `ssh-agent` instead.

This is deliberate: the agent keeps the authenticated PIV session alive, while the YubiKey still enforces physical touch for every signature.

### Do not use persistent SSH multiplexing

Avoid:

```sshconfig
ControlMaster auto
ControlPersist 12h
```

if the intended policy is "touch for every new Git/SSH operation".

With multiplexing, subsequent Git commands can reuse an already authenticated SSH connection and therefore perform no new YubiKey signature at all.

## 9. Optional SSH wrapper

Optionally install a convenient local wrapper at:

```text
/usr/local/bin/ssh-yubikey
```

Example:

```sh
#!/bin/sh

PUB="$HOME/.ssh/id_ed25519.pub"
LIFETIME="12h"

if [ -f /usr/local/lib/libykcs11.dylib ]; then
    PROVIDER="/usr/local/lib/libykcs11.dylib"
elif [ -f /opt/homebrew/lib/libykcs11.dylib ]; then
    PROVIDER="/opt/homebrew/lib/libykcs11.dylib"
else
    echo "ERROR: libykcs11.dylib not found" >&2
    exit 1
fi

if [ ! -r "$PUB" ]; then
    echo "ERROR: SSH public key not found: $PUB" >&2
    exit 1
fi

want="$(awk '{print $1 " " $2}' "$PUB")"

if ! /usr/bin/ssh-add -L 2>/dev/null \
    | awk '{print $1 " " $2}' \
    | grep -Fxq "$want"
then
    echo ">>> Loading YubiKey into ssh-agent ($LIFETIME) <<<" >&2

    SSH_ASKPASS_REQUIRE=never \
      /usr/bin/ssh-add \
      -t "$LIFETIME" \
      -s "$PROVIDER" \
      </dev/tty >/dev/tty 2>/dev/tty \
      || exit 1
fi

printf '\n\033[1;33m>>> TOUCH YUBIKEY <<<\033[0m\a\n\n' >&2

exec /usr/bin/ssh "$@"
```

Permissions:

```bash
sudo chown root:wheel /usr/local/bin/ssh-yubikey
sudo chmod 755 /usr/local/bin/ssh-yubikey
```

The wrapper intentionally sets:

```text
SSH_ASKPASS_REQUIRE=never
```

only for the `ssh-add` operation.

Do **not** set this globally across the macOS GUI session. GUI applications or non-interactive workflows may legitimately depend on an askpass helper.

The explicit `/dev/tty` redirection makes the PIV PIN prompt appear in the user's current terminal.

## 10. Configure Git for SSH transport and SSH commit signing

Make Git use the SSH wrapper for repository access:

```bash
git config --global \
  core.sshCommand \
  /usr/local/bin/ssh-yubikey
```

Configure Git commit signing to use the same hardware-backed PIV key through SSH signing:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

Verify:

```bash
git config --global --get core.sshCommand
git config --global --get gpg.format
git config --global --get user.signingkey
git config --global --get commit.gpgsign
```

Expected:

```text
/usr/local/bin/ssh-yubikey
ssh
~/.ssh/id_ed25519.pub
true
```

The first Git/SSH operation after the agent identity has expired behaves like:

```text
$ git pull

>>> Loading YubiKey into ssh-agent (12h) <<<
Enter passphrase for PKCS#11:

>>> TOUCH YUBIKEY <<<
```

Subsequent SSH operations during the configured lifetime require touch but normally no additional PIV PIN.

A signed commit also requires the YubiKey because Git asks OpenSSH to create an SSH signature using the matching agent key:

```bash
git commit --allow-empty -m "hardware-signing-test"
```

With `commit.gpgsign=true`, no `-S` is required.

For local verification with `git log --show-signature`, you may additionally configure an `allowedSignersFile`. For GitHub verification, register the same public key separately as both an Authentication key and a Signing key.

**GitHub note:** when using the same SSH public key for authentication and SSH Git signing, add it **twice** in GitHub → Settings → SSH and GPG keys: once as **Authentication Key** and once as **Signing Key**. An OpenPGP signing key follows a separate registration path described in §20.

## 11. Direct SSH test

Test without Git:

```bash
ssh -T git@github.com
```

Verbose diagnostics:

```bash
ssh -vvv -T git@github.com
```

Compare the offered key with:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

## 12. Optional handover to another person

For personal use, you are both the person provisioning the token and its eventual user. If setting up a device for someone else, separate **software installation** from **token handover**.

### Phase A: Install prerequisites on the Mac

Install or make available:

```text
1. Yubico PIV Tool universal macOS package
2. /usr/local/bin/ssh-yubikey
3. optionally a documented SSH configuration fragment
```

Recommended wrapper ownership:

```text
root:wheel
0755
```

Do not embed PINs, PUKs, private keys, or Management Keys in scripts or configuration committed to Git.

### Phase B: Token setup and optional handover

Provision the YubiKey using §3:

```text
1. change and securely back up the PUK
2. change and securely back up the PIV Management Key
3. generate the Ed25519 private key on-device in PIV 9a
4. enforce PIN policy ONCE and touch policy ALWAYS
5. create the PIV certificate with the chosen subject
6. export ~/.ssh/id_ed25519.pub
7. record the public-key fingerprint
```

The token owner then:

```text
1. changes the temporary/default PIV PIN to a personal PIN
2. receives only the public SSH key file on disk
3. registers the public key in GitHub (twice if used for both SSH authentication and signing)
4. loads the PKCS#11 identity into ssh-agent
5. tests SSH authentication and Git SSH commit signing
```

Run `ssh-add -s ...` interactively in the intended user session, not as an unattended background job.

The PIV PIN prompt and hardware touch belong to the logged-in user's interactive session.

## 13. Example interactive provisioning sequence

This is an example for setting up your own YubiKey, or a separate device for another person. Run interactively; do not put secrets in shell history or public configuration.

```bash
EMAIL="user@example.com"
PUBTMP="/tmp/yubikey-9a-ed25519-public.pem"

# Confirm the intended token/firmware.
ykman info

# Recovery and management secrets (store securely).
ykman piv access change-puk
ykman piv access change-management-key --algorithm AES192 --generate

# Generate the non-exportable key on-device.
ykman piv keys generate \
  --algorithm ED25519 \
  --pin-policy ONCE \
  --touch-policy ALWAYS \
  9a "$PUBTMP"

# Add optional identity metadata to the PIV certificate.
ykman piv certificates generate \
  --subject "CN=${EMAIL}" \
  --valid-days 3650 \
  9a "$PUBTMP"

# Export a standard OpenSSH public key.
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [ -f /usr/local/lib/libykcs11.dylib ]; then
  PROVIDER=/usr/local/lib/libykcs11.dylib
else
  PROVIDER=/opt/homebrew/lib/libykcs11.dylib
fi

ssh-keygen -D "$PROVIDER" \
  | awk -v email="$EMAIL" 'NR==1 { print $1, $2, email }' \
  | tee ~/.ssh/id_ed25519.pub

chmod 600 ~/.ssh/id_ed25519.pub
ssh-keygen -lf ~/.ssh/id_ed25519.pub
ykman piv keys info 9a

rm -f "$PUBTMP"
```

Verify before relying on the key:

```text
[ ] key type is Ed25519
[ ] key origin is generated on-chip
[ ] PIN policy is ONCE
[ ] touch policy is ALWAYS
[ ] PUK is not factory default and is stored securely
[ ] Management Key is not factory default and is stored securely
[ ] Management Key was NOT stored on-device with --protect
[ ] ~/.ssh/id_ed25519.pub begins with ssh-ed25519
[ ] public-key comment matches the chosen email
[ ] no ~/.ssh/id_ed25519 private-key file exists
```

## 14. Optional shared SSH configuration

On a shared Mac, an SSH configuration fragment can be used instead of editing each user's complete `~/.ssh/config`. For a personal Mac, `~/.ssh/config` is usually simpler.

For example:

```text
/etc/ssh/ssh_config.d/90-yubikey.conf
```

with:

```sshconfig
Host *
  ForwardAgent no
  ForwardX11 no
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519.pub
  ControlMaster no
```

Be aware that OpenSSH option precedence and user-specific configuration must be tested against the existing SSH configuration.

An SSH config file is not an immutable hardware security policy. The on-device touch policy is the hardware-enforced part; check SSH options again if you later change your configuration.

## 15. Local verification checks

Useful checks include:

### PIV key policy

```bash
ykman piv keys info 9a
```

Required:

```text
Algorithm/type: Ed25519
PIN policy:     Once
Touch policy:   Always
```

Also verify that the PIV Management Key and PUK are no longer at factory defaults.

### YKCS11 installed

```bash
test -r /usr/local/lib/libykcs11.dylib
```

### Wrapper installed correctly

```bash
test -x /usr/local/bin/ssh-yubikey
```

### Public identity present for the logged-in user

```bash
test -r "$HOME/.ssh/id_ed25519.pub"
```

### Fingerprint readable

```bash
ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub"
```

### Git wrapper configured (if used)

```bash
git config --global --get core.sshCommand
```

Expected:

```text
/usr/local/bin/ssh-yubikey
```

Run checks requiring PIN entry or touch only in an interactive session.

## 16. Troubleshooting

### `agent refused operation`

Check that the PKCS#11 provider exists:

```bash
ls -l /usr/local/lib/libykcs11.dylib
```

or:

```bash
ls -l /opt/homebrew/lib/libykcs11.dylib
```

Verify direct PKCS#11 enumeration:

```bash
ssh-keygen -D /usr/local/lib/libykcs11.dylib
```

Check the current agent:

```bash
echo "$SSH_AUTH_SOCK"
ssh-add -L
```

Then retry:

```bash
SSH_ASKPASS_REQUIRE=never \
ssh-add -t 12h \
  -s /usr/local/lib/libykcs11.dylib \
  </dev/tty >/dev/tty 2>/dev/tty
```

### The wrong public key is registered in GitHub

Always re-export directly from PIV slot `9a`:

```bash
ykman piv keys export \
  9a \
  /tmp/yubikey-9a-public.pem

ssh-keygen -i -m PKCS8 \
  -f /tmp/yubikey-9a-public.pem \
  > ~/.ssh/id_ed25519.pub

ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

### Touch is not requested

Check for SSH multiplexing:

```bash
ssh -G github.com | grep -Ei 'controlmaster|controlpersist|controlpath'
```

The expected policy for this setup is:

```text
controlmaster no
```

Also make sure Git actually uses the wrapper:

```bash
git config --global --get core.sshCommand
```

### PIN is requested every time

The provider is probably not remaining loaded in the same `ssh-agent`.

Check:

```bash
ssh-add -L
```

If the YubiKey public key is absent, load it again:

```bash
ssh-add \
  -t 12h \
  -s /usr/local/lib/libykcs11.dylib
```

### Laptop sleep/wake problems

If the agent/provider becomes stale after sleep, remove and reload the PKCS#11 provider:

```bash
ssh-add -e /usr/local/lib/libykcs11.dylib 2>/dev/null || true
ssh-add -t 12h -s /usr/local/lib/libykcs11.dylib
```

The wrapper will normally recover automatically when the expected public identity is no longer visible through the agent.

## 17. Security model

This setup deliberately separates three controls.

### Private-key protection

```text
Ed25519 private key
→ YubiKey PIV
→ not stored as a normal private-key file on the Mac
```

### PIN authentication

```text
PIN policy ONCE
+
ssh-agent identity lifetime 12h
→ PIN normally entered once per configured period
```

### Explicit user presence

```text
Touch policy ALWAYS
+
ControlMaster disabled
→ each new SSH signature requires physical YubiKey touch
```

This is materially different from keeping an unlocked software SSH private key in `ssh-agent`.

The agent can request signatures from the YubiKey, but it does not obtain an exportable copy of the hardware private key.

## 18. Suggested personal defaults

A security-conscious personal setup:

```text
YubiKey:
  PIV slot 9a
  Ed25519 key generated on-device
  PIN policy ONCE
  touch policy ALWAYS
  PUK securely backed up
  Management Key securely backed up; this recipe does not use --protect

macOS:
  current supported macOS release
  official Yubico PIV Tool package
  built-in /usr/bin/ssh and ssh-agent

ssh-agent:
  PKCS#11 identity lifetime 12h

SSH:
  IdentitiesOnly yes
  public IdentityFile only
  ForwardAgent no
  ControlMaster no

Git:
  optional ssh-yubikey wrapper
  gpg.format ssh
  user.signingkey ~/.ssh/id_ed25519.pub
  commit.gpgsign true
  visible touch reminder
```

The 12-hour lifetime is an operational choice, not a cryptographic requirement. You can choose a shorter lifetime if you want the identity removed from the agent sooner; actual PIN prompts also depend on the card session.

## 19. Minimal daily-use setup

After setup, the local account needs:

```text
~/.ssh/id_ed25519.pub
~/.ssh/config
```

Installed components:

```text
/usr/local/lib/libykcs11.dylib
/usr/local/bin/ssh-yubikey
```

No ordinary SSH private-key file is required on the Mac. In particular, `~/.ssh/id_ed25519` must not exist; only `~/.ssh/id_ed25519.pub` is stored locally.

## 20. OpenPGP on the same YubiKey for signing and encryption

PIV and OpenPGP are **separate applications** on a YubiKey 5. The PIV SSH key in slot `9a` is independent of the OpenPGP signing (`SIG`), decryption (`DEC`/`ENC`), and optional authentication (`AUT`) keys. This is useful if you want **SSH for access** and **OpenPGP signatures for Git commits, tags, files, or email** without sharing the same cryptographic identity or algorithm. It is also possible to import existing OpenPGP secret keys rather than creating new ones.

### 20.1 Install and verify GnuPG on macOS

Use one consistent GnuPG installation. For a Homebrew-based setup:

```bash
brew install gnupg pinentry-mac yubikey-manager
command -v gpg ykman
gpg --version
ykman info
```

When using GPG Suite instead, check that the intended `gpg`, `gpg-agent`, `scdaemon`, and Pinentry are from compatible installations. For Homebrew, set up the Mac's PC/SC reader if GnuPG and the YubiKey manager contend for the USB device:

```bash
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg
cat > ~/.gnupg/scdaemon.conf <<'EOF'
disable-ccid
pcsc-shared
EOF
chmod 600 ~/.gnupg/scdaemon.conf
gpgconf --kill scdaemon
gpg --card-status
```

If using a graphical Pinentry, check its executable path and configure `pinentry-program` in `~/.gnupg/gpg-agent.conf` only if it is not discovered automatically. Never save the card PIN in the macOS Keychain as part of these provisioning steps.

### 20.2 Choose how the OpenPGP keys are created

**Option A — existing OpenPGP identity (recommended for continuity and recoverable backups).** Use the complete [macOS migration guide](migration/yubikey-openpgp-key-migration-howto-macOS-EN.md). It prepares an isolated RAM disk and a full **pre-`keytocard` backup**, sets key attributes and KDF, moves the primary signing key and encryption subkey, and verifies both operations before cleanup. Do not treat the post-migration card stubs as a backup of private keys. A separate encrypted offline master backup is essential.

**Option B — generate new OpenPGP keys directly on the device.** GnuPG can generate an OpenPGP identity with on-card private-key material through the interactive card editor:

```bash
gpg --card-edit
```

Within the interactive editor, inspect available commands, select `admin`, configure supported key attributes as desired, then choose `generate`. Confirm the intended identity and verify with `gpg --card-status` and `gpg --list-secret-keys`. **On-device generated private keys cannot be exported for a backup**: if the YubiKey is lost or reset, you will need replacement keys. For a reproducible, multi-token identity, use the offline-master/import workflow in the migration guide instead.

The OpenPGP applet has its **own** User PIN and Admin PIN. They are not the PIV PIN, PUK, or Management Key. Do not leave factory PINs in place. Use `gpg --card-edit` → `admin` → `passwd` to change the OpenPGP PINs after provisioning, using the order and KDF cautions from the migration guide where applicable.

### 20.3 Require hardware touch for OpenPGP operations

After signing and encryption keys are installed, enforce physical touch for both. This setup uses **fixed** policies, meaning the touch requirement cannot be relaxed for those keys without replacing their private key material:

```bash
ykman openpgp keys set-touch sig fixed
ykman openpgp keys set-touch enc fixed
ykman openpgp info
gpg --card-status
```

Check `ykman openpgp keys set-touch --help` for the encryption-slot name accepted by your installed version (`enc` or `dec`). Enable `aut fixed` separately only if you also provision the OpenPGP authentication slot. PIV `touch ALWAYS` and OpenPGP `fixed` are independent policies.

### 20.4 Test OpenPGP signing and decryption

Use a disposable file and an existing encryption-capable key in your keyring:

```bash
printf 'OpenPGP hardware test\n' > /tmp/yubikey-openpgp-test.txt
gpg --detach-sign /tmp/yubikey-openpgp-test.txt
gpg --verify /tmp/yubikey-openpgp-test.txt.sig /tmp/yubikey-openpgp-test.txt
gpg --list-secret-keys --keyid-format LONG
```

For the encryption/decryption test, use the recipient fingerprint shown by `gpg --list-keys` or `gpg --card-status`:

```bash
GPG_RECIPIENT='REPLACE_WITH_YOUR_FINGERPRINT'
gpg --recipient "$GPG_RECIPIENT" --encrypt /tmp/yubikey-openpgp-test.txt
gpg --decrypt /tmp/yubikey-openpgp-test.txt.gpg
```

The decryption test only succeeds when the corresponding encryption key is installed and available through the card. Signing and decryption should both require touch under the `fixed` policy.

### 20.5 Choose Git signing independently from SSH authentication

For **OpenPGP Git commit/tag signing**, instead of the SSH signing configuration in §10, configure Git to use GnuPG and your OpenPGP signing key:

```bash
git config --global gpg.format openpgp
git config --global gpg.program "$(command -v gpg)"
git config --global user.signingkey 'REPLACE_WITH_YOUR_OPENPGP_SIGNING_FINGERPRINT'
git config --global commit.gpgsign true
```

Publish the **OpenPGP public key** to GitHub under **Settings → SSH and GPG keys → New GPG key**. This is separate from registering the PIV SSH public key for repository authentication. Git's global signing format is either `ssh` **or** `openpgp` at a time; use a per-repository override if different repositories need different formats.

### 20.6 Switching between PIV and OpenPGP

Using GnuPG, Yubico Authenticator/OATH and PKCS#11 with the same physical token can cause reader/applet switching issues. The [Debian SSH and OpenPGP guide](yubikey-piv-ssh-and-gpg-setup-debian.md) documents a **Debian-specific** PC/SC warm-reset workaround; do not copy its Linux paths or assume the same fix is needed on macOS. On macOS, first validate repeated SSH ↔ OpenPGP operations with the actual PIV provider, `ssh-agent`, `scdaemon`, and `ykman` versions.

For an existing RSA SSH key, consult the [PIV SSH migration instructions](migration/yubikey-piv-ssh-key-migration-howto-debian-EN.md) as a conceptual reference, but adapt the Linux library and temporary-file paths for macOS. For existing OpenPGP keys, use the dedicated [macOS migration instructions](migration/yubikey-openpgp-key-migration-howto-macOS-EN.md).

