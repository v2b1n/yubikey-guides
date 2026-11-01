# Yubico Security Key for SSH and Git signing on macOS — Setup Guide

> Target: macOS.
>
> This guide covers setting up **Security Key by Yubico** devices for SSH authentication and Git signing.
>
> Configuration choices:
>
> - use the Yubico **FIDO2** application, not PIV;
> - generate an **ED25519_SK** SSH credential;
> - make the credential **resident/discoverable** on the security key;
> - require **physical touch** for every SSH signature;
> - protect the local key-handle file with a **non-empty passphrase**;
> - use `ssh-agent` with a 12-hour key lifetime for convenience while keeping physical touch mandatory;
> - omit `verify-required` in the recommended setup; enable it for additional per-signature user verification;
> - use the same key for GitHub/GitLab SSH authentication and Git SSH commit/tag signing;
> - use the standard OpenSSH files:
>   - `~/.ssh/id_ed25519_sk`
>   - `~/.ssh/id_ed25519_sk.pub`
> - the `id_ed25519_sk` file is only a **key handle/reference**, not an export of the private key;
> - the actual private key remains in the hardware security key.

---

## 1. Compatibility requirements

FIDO-backed SSH keys require OpenSSH support for the special security-key algorithms:

```text
sk-ssh-ed25519@openssh.com
sk-ecdsa-sha2-nistp256@openssh.com
```

For this guide use:

```text
ED25519_SK
```

Requirements:

```text
OpenSSH client: 8.2 or newer
Git for SSH commit signing: Git 2.34 or newer
GitHub: ED25519_SK supported
```

Check:

```bash
ssh -V
git --version
```

GitHub and GitLab support `ED25519_SK` and `ECDSA_SK` for both SSH authentication and SSH commit/tag signing.

Important compatibility note:

`ED25519_SK` is **not** the same as ordinary `ssh-ed25519`.

The public key begins with:

```text
sk-ssh-ed25519@openssh.com
```

Every SSH server, appliance, proxy, control-plane API, or other component that parses the key type must support OpenSSH security-key (`*-sk`) algorithms (They usually do in 2026).

For ordinary modern Linux/OpenSSH and GitHub this is normally fine. Legacy systems and some cloud/control-plane key-import interfaces may not accept `*-sk` keys. Use a separate PIV-based procedure for those edge cases.

Official references:

- https://developers.yubico.com/SSH/Securing_SSH_with_FIDO2.html
- https://developers.yubico.com/SSH/
- https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account
- https://docs.github.com/en/authentication/connecting-to-github-with-ssh/testing-your-ssh-connection
- https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification
- https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key

---

## 2. Supported hardware

This procedure is suitable for:

```text
Security Key by Yubico
Security Key C NFC
YubiKey 5 Series
YubiKey Bio Series
```

Only FIDO2 support is required.

Unlike the PIV procedure, this setup does **not** require:

```text
PIV
OpenPGP
YKCS11 / PKCS#11
yubico-piv-tool
```

No Yubico middleware is required for normal operation. OpenSSH talks to the FIDO authenticator directly.

---

## 3. Verify the security key

Insert the intended device and check it:

```bash
ykman info
```

Verify that FIDO2 is enabled.

Typical relevant state:

```text
Applications    USB
FIDO U2F        Enabled
FIDO2           Enabled
```

If Yubico OTP is not required, it may be disabled separately:

```bash
ykman config usb --disable OTP
```

This is optional and unrelated to SSH/FIDO2 operation.

---

## 4. Set or verify the FIDO2 PIN

A FIDO2 PIN is required for resident/discoverable credential management.

Check FIDO2 information:

```bash
ykman fido info
```

If no FIDO2 PIN is configured, set one:

```bash
ykman fido access change-pin
```

On a new device this prompts for a new PIN.

If the key is being prepared for someone else, a suitable handover is:

```text
person preparing the key:
  confirms FIDO2 is functional

key owner:
  chooses the final FIDO2 PIN during handover
```

The person preparing the key should not retain the key owner's final FIDO2 PIN.

### Choose the signing policy: convenience vs. security

The **local key-handle passphrase** encrypts `~/.ssh/id_ed25519_sk` on this Mac. It is **separate from the FIDO2 PIN**, which protects credential management and can optionally verify each signature. Choose a policy before generating the key in section 5:

1. **Recommended — encrypted local handle + touch:** keep `-O verify-required` **disabled**, but set a **strong, non-empty local passphrase** when `ssh-keygen` prompts for it. Load the handle into `ssh-agent` for 12 hours (section 10), so you normally enter this passphrase only when loading it. Every SSH/Git signature still requires touching the Security Key. If malware steals a copy of the encrypted handle file, it cannot use that copy without the passphrase (and the physical Security Key).
2. **Stronger, less convenient — encrypted local handle + PIN + touch:** also add `-O verify-required` to the `ssh-keygen` command in section 5. Every signature then requires FIDO2 user verification (typically the PIN, or supported biometrics) in addition to touch. `ssh-agent` **cannot cache FIDO2 user verification**; support for the prompt may depend on the SSH client/agent setup.
3. **Not recommended — unencrypted local handle + touch only:** omit `-O verify-required` **and** leave the local passphrase empty. Someone who obtains both a copy of the handle and the physical Security Key can sign with touch alone, without knowing either password.

**Limits of local encryption:** the passphrase protects this *particular local handle file*, not the resident credential on the Security Key. Someone who has the token **and knows its FIDO2 PIN** can recover a new handle with `ssh-keygen -K` and choose a different (or empty) local passphrase. Also, malware with access to an **already-unlocked ssh-agent** can request signatures without the local passphrase while the key is loaded; touch is still required. The 12-hour timeout limits how long the agent retains the unlocked handle, not how long a PIN is cached.

A YubiKey 5 also supports a **separate PIV** setup with `PIN policy ONCE` and `touch policy ALWAYS`: one PIN verification per PIV session, with touch for every key operation. This is **not** a fixed 12-hour PIN cache and does not apply to FIDO2 keys. The Security Key by Yubico series does not support PIV.

The remaining steps use the **recommended encrypted-handle + touch** configuration by default.

---

## 5. Generate the resident ED25519_SK SSH credential

Set the email address first:

```bash
EMAIL="user@example.com"
```

Create the SSH directory:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
```

Generate the FIDO2-backed resident key:

```bash
ssh-keygen \
  -t ed25519-sk \
  -O resident \
  -O application=ssh:example-com \
  -C "$EMAIL" \
  -f ~/.ssh/id_ed25519_sk
```

During generation OpenSSH may ask for the FIDO2 PIN and will require touching the security key.

When prompted with `Enter passphrase (empty for no passphrase):`, enter and confirm a **strong, non-empty passphrase**. This encrypts the local key-handle file and is required for the recommended setup. It is **not** the FIDO2 PIN. Section 10 shows how to unlock it through `ssh-agent` for 12 hours.

The resulting files are:

```text
~/.ssh/id_ed25519_sk
~/.ssh/id_ed25519_sk.pub
```

Important distinction:

```text
~/.ssh/id_ed25519_sk
```

is **not an exported private key**.

It is a small OpenSSH key-handle/reference file that tells OpenSSH which credential to use on the hardware authenticator.

The cryptographic private key remains inside the Security Key.

The public key is a normal text file:

```text
~/.ssh/id_ed25519_sk.pub
```

and should look like:

```text
sk-ssh-ed25519@openssh.com AAAA... user@example.com
```

---

## 6. Verify the generated key

Check the public key:

```bash
cat ~/.ssh/id_ed25519_sk.pub
ssh-keygen -lf ~/.ssh/id_ed25519_sk.pub
```

Expected key type:

```text
ED25519-SK
```

Expected public-key prefix:

```text
sk-ssh-ed25519@openssh.com
```

The email address must be present as the comment.

Set file permissions:

```bash
chmod 600 ~/.ssh/id_ed25519_sk
chmod 644 ~/.ssh/id_ed25519_sk.pub
```

---

## 7. Confirm that touch is required

Touch/user presence is required by default for OpenSSH FIDO security-key credentials.

Do **not** generate the key with:

```text
-O no-touch-required
```

This setup requires physical touch for every private-key operation.

There is no PIV-style mutable `touch-policy` setting here. The user-presence requirement is part of the FIDO/OpenSSH credential behavior established when the credential is created.

---

## 8. Recover the resident credential on another Mac

Because the credential is resident/discoverable on the Security Key, the OpenSSH handle files can be recreated on another compatible machine.

Insert the Security Key and run:

```bash
cd ~/.ssh
ssh-keygen -K
```

OpenSSH will download the resident credential handles from the authenticator.

Rename the downloaded key files to match the names used in this guide if necessary:

```text
~/.ssh/id_ed25519_sk
~/.ssh/id_ed25519_sk.pub
```

The private cryptographic key is still not exported; only the local handle/reference is reconstructed. When prompted, **set a non-empty passphrase on the recovered handle too**: it is a new local file, and its passphrase is independent of the passphrase on the original Mac.

---

## 9. Register the key in GitHub

The public key to register is:

```text
~/.ssh/id_ed25519_sk.pub
```

In GitHub, go to **Settings → SSH and GPG keys** and add the **same public key twice**:

1. **New SSH key** → **Key type: Authentication Key** — for repository access over SSH.
2. **New SSH key** → **Key type: Signing Key** — for Git commit/tag signing.

GitHub requires two separate entries when the same SSH public key is used for both purposes; **no second key pair is needed**.

The Git committer email must match a verified email address on the GitHub account for GitHub to show the signature as verified.

---

## 10. Configure SSH and ssh-agent

Example `~/.ssh/config`:

```sshconfig
Host *
  ServerAliveInterval 30

  ForwardX11 no
  ForwardAgent no

  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519_sk
  AddKeysToAgent 12h

  # Require a new SSH authentication/signature for each new connection.
  ControlMaster no
```

`AddKeysToAgent 12h` automatically adds the decrypted local handle to a running `ssh-agent` for up to **12 hours** when SSH loads it from disk. This does **not** store the handle passphrase in the agent or cache the FIDO2 PIN; the agent retains an unlocked handle for that lifetime. After expiry, the local passphrase is needed again to reload the handle. Physical touch is still required for every signature.

**Before testing SSH in section 11**, explicitly load the encrypted handle into your running agent:

```bash
ssh-add -t 12h ~/.ssh/id_ed25519_sk
ssh-add -l
```

`ssh-add` asks for the **local handle passphrase once**, then lists the loaded `ED25519-SK` identity. The 12-hour lifetime applies to this agent entry (not to the Security Key itself); if the agent exits sooner, the entry is lost sooner. A normal macOS login generally already provides an agent; otherwise start a compatible `ssh-agent` first. Use an OpenSSH/agent combination with FIDO security-key support, as some macOS system and Homebrew combinations differ. If you want the lifetime to be strictly 12 hours, avoid separately saving the handle passphrase persistently in macOS Keychain.

If you selected `-O verify-required`, the agent can still hold the unlocked handle but **cannot suppress the PIN/user-verification prompt** on subsequent signatures.

---

## 11. Test SSH authentication

Test GitHub:

```bash
ssh -T git@github.com
```

Expected behavior:

```text
SSH requests the ED25519_SK key
→ YubiKey flashes
→ user touches the key
→ Hi USERNAME! You've successfully authenticated, but GitHub does not provide shell access.
```

This success message is expected; `ssh -T` may exit with status 1 because GitHub does not provide a shell.

For diagnostics:

```bash
ssh -vvv -T git@github.com
```

Look for the key type:

```text
sk-ssh-ed25519@openssh.com
```

---

## 12. Configure Git SSH commit and tag signing

Configure Git:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_sk.pub
git config --global commit.gpgsign true
```

Verify:

```bash
git config --global --get gpg.format
git config --global --get user.signingkey
git config --global --get commit.gpgsign
```

Expected:

```text
ssh
~/.ssh/id_ed25519_sk.pub
true
```

A normal commit now requires the hardware key:

```bash
git commit -m "hardware-signing-test"
```

Expected behavior:

```text
Git requests SSH signature
→ YubiKey flashes
→ developer touches Security Key
→ commit is signed
```

No OpenPGP configuration is involved.

Tags can also be SSH-signed:

```bash
git tag -s v1.2.3 -m "v1.2.3"
```

---

## 13. Local signature verification

GitHub verifies the signature using the SSH public key associated with the user's GitHub account.

For local verification with:

```bash
git log --show-signature
```

configure an `allowedSignersFile`, for example:

```bash
mkdir -p ~/.config/git

printf '%s %s\n' \
  "$EMAIL" \
  "$(cat ~/.ssh/id_ed25519_sk.pub)" \
  > ~/.config/git/allowed_signers

git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
```

---

## 14. Setup checklist

For each security key:

```text
[ ] correct Security Key is physically present
[ ] FIDO2 is enabled
[ ] FIDO2 PIN is set/confirmed
[ ] ED25519_SK resident credential generated
[ ] application name is ssh:example-com
[ ] email address is the SSH key comment
[ ] no -O no-touch-required option was used
[ ] local handle is encrypted with a strong, non-empty passphrase
[ ] recommended policy: no -O verify-required (or explicitly chosen PIN + touch)
[ ] ssh-agent loaded the handle using ssh-add -t 12h
[ ] ssh-add -l lists the ED25519-SK identity
[ ] ~/.ssh/id_ed25519_sk exists
[ ] ~/.ssh/id_ed25519_sk.pub exists
[ ] public key begins with sk-ssh-ed25519@openssh.com
[ ] public key registered twice on GitHub: Authentication Key and Signing Key
[ ] SSH login to GitHub succeeds with physical touch
[ ] gpg.format = ssh
[ ] user.signingkey = ~/.ssh/id_ed25519_sk.pub
[ ] commit.gpgsign = true
[ ] signed Git commit succeeds with physical touch
```

---

## 15. Security model

### Private-key protection

```text
ED25519_SK private key
→ generated for FIDO2 security-key credential
→ remains protected by the hardware authenticator
→ not stored as an exportable software private key
```

### Local handle file

```text
~/.ssh/id_ed25519_sk
→ OpenSSH credential handle/reference
→ not the cryptographic private key itself
```

The recommended setup additionally **encrypts this local file with a passphrase**, protecting a stolen copy from offline use. A copied handle still requires the corresponding physical Security Key. A resident credential can be recovered to a *new* handle with the token and its FIDO2 PIN, independently of this file's passphrase.

### User presence

```text
touch required
→ enforced through the FIDO/OpenSSH security-key operation
→ every actual SSH signature requires physical possession and touch
```

### FIDO2 PIN

The FIDO2 PIN protects credential management and can also be used for per-operation user verification when `verify-required` is enabled.

In the recommended setup, `verify-required` is intentionally **not** enabled; instead, the **encrypted local handle** is unlocked with a passphrase and held in `ssh-agent` for up to **12 hours**. That does not protect against malware able to use the unlocked agent, but hardware touch remains mandatory for every signature. Enable `verify-required` for stronger per-signature verification if needed.

---

## 16. Important compatibility limitation

This is the main trade-off compared with the PIV-based setup.

The server sees:

```text
sk-ssh-ed25519@openssh.com
```

not:

```text
ssh-ed25519
```

Therefore every component that parses/validates the SSH key type must support OpenSSH security-key algorithms.

Known classes of possible incompatibility include:

```text
older OpenSSH servers (< 8.2)
legacy SSH appliances
some cloud/control-plane SSH-key import APIs
some embedded SSH libraries
some FIPS environments/policies
```

For such systems, use a separate PIV-based YubiKey procedure instead.

For a typical modern setup:

```text
macOS
→ modern OpenSSH
→ GitHub
→ modern Linux/OpenSSH
```

`ED25519_SK` is the preferred lightweight setup.

---

## 17. Minimal user-visible setup

After setup, the user needs only:

```text
Security Key by Yubico
~/.ssh/id_ed25519_sk
~/.ssh/id_ed25519_sk.pub
~/.ssh/config
ssh-agent (12-hour lifetime for the encrypted local handle)
Git configuration
```

No PIV middleware, PKCS#11 library, YKCS11 agent wrapper, OpenPGP configuration, or software private SSH key is required.
