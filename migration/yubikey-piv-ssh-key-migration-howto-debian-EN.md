# HowTo: Migrate an Existing SSH RSA Key to YubiKey via PIV

This document describes how to migrate an **existing RSA SSH private key** to a YubiKey 5.x via PIV slot `9a` (Authentication), with the following mandatory steps:

- Change the PIV PIN
- Change the PIV PUK
- Change the PIV Management Key
- Create and store an X.509 certificate in slot `9a`

> Important: PIV, OpenPGP, FIDO2, OATH, and OTP are independent applications on a YubiKey.  
> `ykman piv reset` resets **only PIV**, but all PIV contents will be deleted.

---

## 1. Check the YubiKey

```bash
ykman info
```

Example:

```text
Device type: YubiKey 5 NFC
Serial number: 12345678
Firmware version: 5.7.1
PIV: Enabled
```

Using RSA4096 with PIV requires a YubiKey that supports RSA4096, for example, one with firmware 5.7.x.

---

## 2. Check the Original SSH Key

Assume the original key is:

```text
~/.ssh/id_rsa
```

Display its fingerprint:

```bash
ssh-keygen -lf ~/.ssh/id_rsa.pub
```

If the private key is in OpenSSH format:

```bash
head -1 ~/.ssh/id_rsa
```

The output will usually be:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
```

---

## 3. Create a Temporary PEM Copy

Leave the original untouched:

```bash
cp ~/.ssh/id_rsa /dev/shm/id_rsa_yubikey.pem
chmod 600 /dev/shm/id_rsa_yubikey.pem
```

Convert the copy to PEM:

```bash
ssh-keygen -p -m PEM -f /dev/shm/id_rsa_yubikey.pem
```

You can keep the same passphrase.

Check the RSA exponent:

```bash
openssl rsa   -in /dev/shm/id_rsa_yubikey.pem   -text -noout   | grep publicExponent
```

For YubiKey PIV, it must be:

```text
publicExponent: 65537 (0x10001)
```

If the exponent is different, for example:

```text
publicExponent: 35 (0x23)
```

This RSA key pair cannot be imported into PIV without changing the SSH identity. A new RSA key with `e=65537` must be created.

---

## 4. If PIV Needs to Be Reset

First, check its current state:

```bash
ykman piv info
```

If PIV contains existing keys/certificates that are still needed, **do not perform a reset**.

If all PIV contents can be erased:

```bash
ykman piv reset
```

Factory-default values after a reset:

```text
PIN:            123456
PUK:            12345678
Management Key: default
```

---

## 5. MANDATORY: Change the PIV PIN

```bash
ykman piv access change-pin
```

After a reset, the current PIN is:

```text
123456
```

Verify:

```bash
ykman piv info
```

The warning `Using default PIN!` should disappear.

---

## 6. MANDATORY: Change the PIV PUK

```bash
ykman piv access change-puk
```

After a reset, the current PUK is:

```text
12345678
```

The PUK is used to unblock the PIN. The default PUK must not be left unchanged: someone with physical access to the YubiKey could block the PIN and then set a new PIN using the known default PUK.

After changing it:

```bash
ykman piv info
```

The warning `Using default PUK!` should disappear.

---

## 7. MANDATORY: Change the PIV Management Key

A convenient option is to generate a random Management Key and store it on the YubiKey itself, protected by the PIV PIN:

```bash
ykman piv access change-management-key --generate --protect
```

After that:

```bash
ykman piv info
```

It should display:

```text
Management key is stored on the YubiKey, protected by PIN.
```

Changing the Management Key **does not erase** any PIV keys/certificates already stored on the device.

---

## 8. Import the SSH Private Key into PIV Slot 9a

Slot `9a` is the standard PIV Authentication slot.

```bash
ykman piv keys import   --pin-policy ONCE   --touch-policy ALWAYS   9a /dev/shm/id_rsa_yubikey.pem
```

What these policies mean:

```text
PIN policy ONCE     PIN is required once per PIV session
touch policy ALWAYS Physical touch is required for every private-key operation
```

Verify:

```bash
ykman piv info
```

After importing, the output should include:

```text
Slot 9A (AUTHENTICATION):
  Private key type: RSA4096
```

---

## 9. Create a Public Key in PEM Format

From the original private key:

```bash
openssl pkey   -in /dev/shm/id_rsa_yubikey.pem   -pubout   -out /dev/shm/id_rsa_yubikey-public.pem
```

---

## 10. MANDATORY: Create and Store an X.509 Certificate

PKCS#11/PIV middleware uses the certificate in the same slot.

Generate a self-signed certificate directly in `9a`:

```bash
ykman piv certificates generate   --subject "CN=SSH key"   9a /dev/shm/id_rsa_yubikey-public.pem
```

Verify:

```bash
ykman piv info
```

Example:

```text
Slot 9A (AUTHENTICATION):
  Private key type: RSA4096
  Public key type:  RSA4096
  Subject DN:       CN=SSH key
  Issuer DN:        CN=SSH key
```

---

## 11. Check the SSH Public Key from the YubiKey

Using the Yubico PKCS#11 provider:

```bash
ssh-keygen -D /usr/lib/x86_64-linux-gnu/libykcs11.so   | head -1   | ssh-keygen -lf -
```

Compare it with the original:

```bash
ssh-keygen -lf ~/.ssh/id_rsa.pub
```

The fingerprints must match **exactly**.

---

## 12. Test an Actual SSH Login

For example:

```bash
ssh -I /usr/lib/x86_64-linux-gnu/libykcs11.so user@example-host
```

Expected prompt:

```text
Enter PIN for 'YubiKey PIV #12345678':
```

With `touch-policy ALWAYS`, a physical touch of the YubiKey will be required.

---

## 13. Convenient SSH Configuration

To avoid specifying `-I` every time:

```sshconfig
Host *
    PKCS11Provider /usr/lib/x86_64-linux-gnu/libykcs11.so
```

Or only for the required hosts:

```sshconfig
Host work-*
    PKCS11Provider /usr/lib/x86_64-linux-gnu/libykcs11.so
```

Then this is sufficient:

```bash
ssh work-server
```

---

## 14. If the Same SSH Identity Is Needed on Multiple YubiKeys

The same original private key can be imported into multiple YubiKeys.

Repeat the following for each new YubiKey:

1. Check the serial number using `ykman info`
2. Run `ykman piv reset` if necessary
3. Change the PIN
4. Change the PUK
5. Change the Management Key
6. Import the same private key into `9a`
7. Create an X.509 certificate in `9a`
8. Verify the fingerprint
9. Test an actual SSH login

Do not generate the key pair inside the first YubiKey if multiple identical tokens are required: a private key generated inside PIV cannot be exported afterward.

---

## 15. Clean Up Temporary Files

After successful verification:

```bash
rm -f   /dev/shm/id_rsa_yubikey.pem   /dev/shm/id_rsa_yubikey-public.pem
```

Store the original private key/master backup separately in a securely encrypted form.

---

## Quick Checklist

```text
[ ] YubiKey serial number verified
[ ] PIV PIN changed
[ ] PIV PUK changed
[ ] PIV Management Key changed
[ ] RSA exponent = 65537
[ ] Private key imported into 9a
[ ] X.509 certificate created in 9a
[ ] Fingerprint matches the original SSH key
[ ] Actual SSH login works
[ ] Temporary PEM files deleted
[ ] Master private key stored offline/encrypted
```
