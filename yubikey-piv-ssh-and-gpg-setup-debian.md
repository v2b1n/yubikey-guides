# YubiKey PIV for SSH on Debian

> **YubiKey 5 Series (PIV + OpenPGP), Debian.** This is a personal, hardware-backed SSH setup, not a device-management policy. A YubiKey can generate a non-exportable SSH key inside PIV **or import an existing compatible private key** (see `migration/`). Imported private keys must be protected at their original storage and backup locations. PIV can expose ordinary RSA/ECDSA/Ed25519 SSH public keys rather than FIDO-specific `*-sk` keys; support depends on firmware and PKCS#11 client compatibility. The independent OpenPGP applet can be used for PGP signing/decryption while PIV handles SSH. For macOS, see [the companion guide](yubikey-piv-ssh-and-openpgp-macos.md).

This setup uses a YubiKey PIV key as the primary SSH identity on Debian while keeping the daily workflow reasonably convenient:

- the SSH private key never lives on disk;
- the YubiKey enforces **physical touch for every SSH signature**;
- the PIV PIN is entered only when the PKCS#11 identity is loaded into `ssh-agent`;
- the identity is cached in `ssh-agent` for a fixed period, e.g. **12 hours**;
- Git commands display a visible `TOUCH YUBIKEY` reminder before SSH starts;
- SSH connection multiplexing is disabled, so every new SSH/Git connection really performs a new hardware-backed signature.

The intended result is:

```text
first Git/SSH operation
→ load YubiKey into ssh-agent
→ enter PIV PIN
→ touch YubiKey
→ connect

subsequent Git/SSH operations during the agent lifetime
→ touch YubiKey
→ connect

after the agent key lifetime expires
→ enter PIV PIN again
→ touch YubiKey
→ connect
```

## 1. Requirements

Install the OpenSSH client and Yubico PIV tooling:

```bash
sudo apt install openssh-client yubico-piv-tool ykcs11 python3-pyscard
```

The Yubico PKCS#11 provider is normally available as:

```text
/usr/lib/x86_64-linux-gnu/libykcs11.so
```

Verify:

```bash
find /usr/lib /usr/local/lib -name 'libykcs11.so*' 2>/dev/null
```

The YubiKey must already contain an SSH-capable key in PIV slot `9a` (`AUTHENTICATION`), ideally with:

```text
PIN policy:   ONCE
Touch policy: ALWAYS
```

Example provisioning command:

```bash
ykman piv keys import \
  --pin-policy ONCE \
  --touch-policy ALWAYS \
  9a private-key.pem
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

### OpenPGP touch policy — mandatory if OpenPGP keys are provisioned

If the same YubiKey also contains OpenPGP signing and decryption keys, require a **physical touch for every signature and every decryption operation**, and make that requirement non-disableable for the current key material:

```bash
ykman openpgp keys set-touch sig fixed
ykman openpgp keys set-touch dec fixed
ykman openpgp info
```

Expected:

```text
Signature key:
  Touch policy: On (fixed)

Decryption key:
  Touch policy: On (fixed)
```

`fixed` has the same normal runtime behavior as `on`: every operation requires touch. The difference is that a fixed touch policy cannot later be changed while the current private key remains in that slot; changing it requires deleting/replacing the private key.

For this setup, `sig=fixed` and `dec=fixed` are mandatory.

Official Yubico documentation for `ykman openpgp keys set-touch` and the available policies (`on`, `off`, `fixed`, `cached`, `cached-fixed`):

- https://docs.yubico.com/software/yubikey/tools/ykman/webdocs.pdf — section **OpenPGP Commands → `ykman openpgp keys set-touch`**
- https://developers.yubico.com/yubikey-manager/API_Documentation/autoapi/yubikit/openpgp/index.html — OpenPGP UIF values

## 2. Export the public SSH key

Export the public key from PIV slot `9a`:

```bash
ykman piv keys export 9a /dev/shm/yubikey-9a-public.pem
```

Convert it from PKCS#8 PEM to the normal one-line OpenSSH format:

```bash
ssh-keygen -i -m PKCS8 \
  -f /dev/shm/yubikey-9a-public.pem \
  | tee ~/.ssh/id_rsa_yubikey.pub
```

Check the fingerprint:

```bash
ssh-keygen -lf ~/.ssh/id_rsa_yubikey.pub
```

The `.pub` file contains no private key material and may be registered on GitHub, GitLab, servers, etc.

## 3. Configure SSH

Example `~/.ssh/config`:

```sshconfig
Host *
  ServerAliveInterval 30
  AddressFamily inet

  ForwardX11 no
  ForwardAgent no

  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa_yubikey.pub

  # Important for per-connection YubiKey touch.
  ControlMaster no
```

Do **not** set `PKCS11Provider` here when using the `ssh-agent` workflow below. The provider is loaded into the agent instead.

Also avoid long-lived SSH multiplexing such as:

```sshconfig
ControlMaster auto
ControlPersist 12h
```

if the goal is to require a physical YubiKey touch for every new Git/SSH operation. A multiplexed connection reuses an already authenticated SSH session and therefore does not perform another hardware signature.

## 4. Load the YubiKey into ssh-agent

Make sure an SSH agent is available:

```bash
ssh-add -L
```

If the output is:

```text
The agent has no identities.
```

the agent is running and simply contains no keys.

If there is no running agent in the current shell:

```bash
eval "$(ssh-agent -s)"
```

Load the YubiKey PKCS#11 identity for 12 hours:

```bash
ssh-add -t 12h -s /usr/lib/x86_64-linux-gnu/libykcs11.so
```

This asks for the PIV PIN once.

Check:

```bash
ssh-add -l
ssh-add -L
```

With `touch-policy ALWAYS`, every new SSH signature still requires physical touch even though the agent keeps the PKCS#11 identity loaded.

The `12h` timeout is a fixed lifetime from the moment the identity is added to `ssh-agent`; it is not an idle timeout and is not extended by SSH activity.

To remove the provider manually:

```bash
ssh-add -e /usr/lib/x86_64-linux-gnu/libykcs11.so
```

## 5. Git/SSH wrapper with automatic agent loading

A small wrapper can:

1. check whether the expected YubiKey public key is already available through `ssh-agent`;
2. load the PKCS#11 provider for 12 hours if necessary;
3. force PIN entry through the current terminal rather than a graphical `ssh-askpass`;
4. display a visible `TOUCH YUBIKEY` reminder;
5. execute the real OpenSSH client.

Create:

```text
~/.local/bin/ssh-yubikey
```

with:

```sh
#!/bin/sh

PUB="$HOME/.ssh/id_rsa_yubikey.pub"
PROVIDER="/usr/lib/x86_64-linux-gnu/libykcs11.so"
LIFETIME="12h"

want="$(awk '{print $1 " " $2}' "$PUB")"

if ! ssh-add -L 2>/dev/null \
    | awk '{print $1 " " $2}' \
    | grep -Fxq "$want"
then
    echo ">>> Loading YubiKey into ssh-agent ($LIFETIME) <<<" >&2

    SSH_ASKPASS_REQUIRE=never \
      ssh-add -t "$LIFETIME" -s "$PROVIDER" \
      </dev/tty >/dev/tty 2>/dev/tty \
      || exit 1
fi

printf '\n\033[1;33m>>> TOUCH YUBIKEY <<<\033[0m\a\n\n' >&2

exec /usr/bin/ssh "$@"
```

Make it executable:

```bash
chmod 700 ~/.local/bin/ssh-yubikey
```

`SSH_ASKPASS_REQUIRE=never` is intentionally scoped only to this wrapper. Setting it globally can break GUI or non-interactive SSH workflows that legitimately depend on an askpass helper.

## 6. PC/SC warm reset before every SSH invocation

When the same YubiKey is also used for OpenPGP or OATH, another application can leave a different applet selected on the card. A long-lived `ssh-agent` / `ssh-pkcs11-helper` / `libykcs11` session may then still expose the correct cached public key but fail on the next private-key operation with:

```text
sign_and_send_pubkey: signing failed ... from agent: agent refused operation
```

The verified solution is to perform a **PC/SC warm reset immediately before every SSH invocation**.

The reset does **not** unload and reload the PKCS#11 provider. Instead, it makes `libykpiv` take its reconnect path, re-select PIV, and re-verify using the PIN state it already keeps for the loaded PKCS#11 identity. The normal result is therefore:

```text
OpenPGP / OATH use
→ SSH starts
→ PC/SC warm reset
→ libykcs11 reconnects and selects PIV again
→ no additional PIV PIN prompt
→ physical YubiKey touch is still required
→ SSH succeeds
```

The PIV `touch-policy ALWAYS` remains enforced by the YubiKey firmware; the warm reset does not weaken or bypass it.

### 6.1 Install the helper

Create:

```text
~/.local/bin/yk-warm-reset
```

with:

```python
#!/usr/bin/env python3
# Warm-reset the YubiKey via PC/SC so that other PC/SC clients
# (libykpiv inside ssh-pkcs11-helper) observe SCARD_W_RESET_CARD
# and run their reconnect path, re-verifying the cached PIN.
import sys
from smartcard.scard import (
    SCardEstablishContext, SCardListReaders, SCardConnect,
    SCardDisconnect, SCardReleaseContext, SCardGetErrorMessage,
    SCARD_SCOPE_USER, SCARD_SHARE_SHARED, SCARD_PROTOCOL_T0,
    SCARD_PROTOCOL_T1, SCARD_RESET_CARD, SCARD_S_SUCCESS,
)


def check(rc, what):
    if rc != SCARD_S_SUCCESS:
        sys.exit(f"{what}: {SCardGetErrorMessage(rc)}")


rc, ctx = SCardEstablishContext(SCARD_SCOPE_USER)
check(rc, "SCardEstablishContext")
rc, readers = SCardListReaders(ctx, [])
check(rc, "SCardListReaders")

# Refuse to guess if more than one YubiKey is present.
yk = [r for r in readers if "Yubico" in r]
if len(yk) != 1:
    sys.exit(f"expected exactly one Yubico reader, got: {yk}")

rc, card, _proto = SCardConnect(
    ctx, yk[0], SCARD_SHARE_SHARED, SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1
)
check(rc, "SCardConnect")

# Disconnect with a warm reset - this is the whole point.
rc = SCardDisconnect(card, SCARD_RESET_CARD)
check(rc, "SCardDisconnect")
SCardReleaseContext(ctx)
```

Make it executable:

```bash
chmod 755 ~/.local/bin/yk-warm-reset
```

Manual smoke test:

```bash
~/.local/bin/yk-warm-reset && echo reset-ok
```

Expected:

```text
reset-ok
```

The helper intentionally refuses to choose when more than one reader whose name contains `Yubico` is present. If another YubiKey (for example an old Nano) is plugged in at the same time, the helper exits instead of resetting an arbitrary device.

### 6.2 Trigger the reset from OpenSSH

Append the following block to the **very end** of `~/.ssh/config`:

```sshconfig
# Warm-reset the YubiKey before every ssh invocation so libykcs11
# re-selects PIV and re-verifies its cached PIN after any other
# applet (OpenPGP, OATH) was used. The trailing "false" keeps this
# block from ever matching - it exists only for the side effect.
Match exec "~/.local/bin/yk-warm-reset >/dev/null 2>&1; false"
```

The trailing `false` is deliberate: the command is executed for its side effect, but the `Match` condition itself never becomes true.

**Keep this block at the end of the file.** Every configuration line after a `Match` belongs to that conditional block until another `Host` or `Match` starts. Placing this block earlier could accidentally place later global SSH options inside a condition that never matches.

A safe way to append it while preserving a backup:

```bash
cp ~/.ssh/config /dev/shm/ssh-config.bak

cat >> ~/.ssh/config <<'EOF'

# Warm-reset the YubiKey before every ssh invocation so libykcs11
# re-selects PIV and re-verifies its cached PIN after any other
# applet (OpenPGP, OATH) was used. The trailing "false" keeps this
# block from ever matching - it exists only for the side effect.
Match exec "~/.local/bin/yk-warm-reset >/dev/null 2>&1; false"
EOF

diff -u /dev/shm/ssh-config.bak ~/.ssh/config
```

Then verify that the normal identity configuration is still visible:

```bash
ssh -G github.com | grep -iE '^identit'
```

The expected configuration still includes the intended `IdentitiesOnly` and public `IdentityFile`.

### 6.3 Why the reset is on the SSH side

Do not put the reset only around Git/GPG signing. The applet switch can also be caused by other software, for example OATH/Yubico Authenticator.

Putting the reset at SSH configuration parsing time means the same recovery is applied to:

```text
ssh
scp
sftp
rsync over ssh
Git fetch/pull/push over ssh
```

The existing `~/.local/bin/ssh-yubikey` wrapper stays unchanged.

The resulting flow is:

```text
ssh-yubikey
  → ssh-add -L check (agent cache only)
  → TOUCH YUBIKEY banner
  → exec /usr/bin/ssh
       → parses ~/.ssh/config
       → Match exec runs yk-warm-reset
       → libykcs11 reconnects and selects PIV
       → SSH requests the signature
       → YubiKey requires physical touch
```

### 6.4 End-to-end verification

After the helper and `Match exec` hook are installed, verify the exact failure/recovery sequence:

```bash
ssh -T git@github.com
git commit --allow-empty -S -m "openpgp-switch-test"
ssh -T git@github.com
ykman oath accounts list
ssh -T git@github.com
```

Expected behavior:

```text
first SSH          → touch → succeeds
OpenPGP commit     → OpenPGP authentication/touch → succeeds
second SSH         → touch only, no new PIV PIN → succeeds
OATH operation     → succeeds
third SSH          → touch only, no new PIV PIN → succeeds
```

This is the final tested workaround for the PIV/OpenPGP/OATH applet-switch issue.

## 7. Make Git use the wrapper

Configure Git globally:

```bash
git config --global core.sshCommand ~/.local/bin/ssh-yubikey
```

Check:

```bash
git config --global --get core.sshCommand
```

Expected:

```text
~/.local/bin/ssh-yubikey
```

Now a typical Git operation behaves like:

```text
$ git pull
>>> Loading YubiKey into ssh-agent (12h) <<<
Enter PIN for PKCS#11:
>>> TOUCH YUBIKEY <<<
```

During the next 12 hours:

```text
$ git pull
>>> TOUCH YUBIKEY <<<
```

No PIN is needed again until the identity expires from `ssh-agent`, but each new SSH connection still requires touch.

## 8. Test direct SSH

Test the YubiKey identity independently from Git:

```bash
ssh -T git@github.com
```

Or use verbose mode:

```bash
ssh -vvv -T git@github.com
```

The expected public-key fingerprint should match:

```bash
ssh-keygen -lf ~/.ssh/id_rsa_yubikey.pub
```

## 9. Troubleshooting

### `agent refused operation` after OpenPGP or OATH use

If SSH works after loading the provider but fails after using OpenPGP or OATH on the same YubiKey:

```text
sign_and_send_pubkey: signing failed ... from agent: agent refused operation
```

first verify that the warm-reset helper and the final `Match exec` hook from section 6 are installed.

Manual recovery test:

```bash
~/.local/bin/yk-warm-reset && echo reset-ok
ssh -T git@github.com
```

If this restores SSH without another PIV PIN prompt, the failure is the known applet-selection/reconnect issue addressed by the warm-reset hook.

Do **not** use provider unload/reload as the normal workaround:

```bash
ssh-add -e /usr/lib/x86_64-linux-gnu/libykcs11.so
ssh-add -s /usr/lib/x86_64-linux-gnu/libykcs11.so
```

because recreating the provider session asks for the PIV PIN again and defeats the intended `PIN policy ONCE` workflow.

### `ssh_askpass: ... No such file or directory`

Example:

```text
ssh_askpass: exec(/usr/bin/ssh-askpass): No such file or directory
Could not add card ".../libykcs11.so": agent refused operation
```

This happens when `ssh-add` is launched from a context where it decides to use an askpass helper instead of the terminal.

The wrapper avoids this with:

```sh
SSH_ASKPASS_REQUIRE=never \
ssh-add ... </dev/tty >/dev/tty 2>/dev/tty
```

### `Error connecting to agent: Connection refused`

The shell still points to a dead `ssh-agent` socket, often because the agent process was killed manually.

Start a new one for the current shell:

```bash
eval "$(ssh-agent -s)"
```

Then check:

```bash
ssh-add -L
```

### `Permission denied (publickey)`

Check that the correct public key is configured:

```bash
ssh-keygen -lf ~/.ssh/id_rsa_yubikey.pub
```

Check what the agent exposes:

```bash
ssh-add -L
```

Manually load the YubiKey if needed:

```bash
SSH_ASKPASS_REQUIRE=never \
ssh-add -t 12h -s /usr/lib/x86_64-linux-gnu/libykcs11.so \
</dev/tty >/dev/tty 2>/dev/tty
```

Then retry with:

```bash
ssh -vvv -T git@github.com
```

### Touch is not requested for every Git operation

Make sure SSH multiplexing is disabled:

```sshconfig
ControlMaster no
```

If `ControlMaster auto` / `ControlPersist` is enabled, subsequent Git operations may reuse an already authenticated SSH connection and therefore require no new YubiKey signature.

### Verify the public key directly from the YubiKey

```bash
ykman piv keys export 9a /dev/shm/yubikey-9a-public.pem

ssh-keygen -i -m PKCS8 \
  -f /dev/shm/yubikey-9a-public.pem \
  | ssh-keygen -lf -
```

This is useful when there is any doubt that the local `.pub` file corresponds to the key actually stored in PIV slot `9a`.

## 10. Security properties

With this setup:

```text
Private SSH key:
  YubiKey PIV only
  → not present as an ordinary private-key file on disk

PIV PIN:
  required when PKCS#11 identity is loaded into ssh-agent
  → typically once every configured agent lifetime

Physical touch:
  hardware-enforced by touch-policy ALWAYS
  → required for every actual private-key signature

ssh-agent:
  holds access to the PKCS#11 identity for a limited time
  → does not contain an exportable copy of the YubiKey private key

ControlMaster:
  disabled
  → each new SSH/Git connection performs a fresh signature
```

The important distinction is that `ssh-agent` caching removes repeated PIN entry, while the YubiKey's hardware touch policy continues to require explicit physical user presence for each SSH signature.

## 11. Recommended files

A minimal setup consists of:

```text
~/.ssh/config
~/.ssh/id_rsa_yubikey.pub
~/.local/bin/ssh-yubikey
~/.local/bin/yk-warm-reset
```

No SSH private-key file is required on disk.
