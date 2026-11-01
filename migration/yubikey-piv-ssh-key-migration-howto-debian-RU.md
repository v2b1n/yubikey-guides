# HowTo: перенос существующего SSH RSA-ключа на YubiKey через PIV

Этот документ описывает перенос **существующего RSA SSH private key** на YubiKey 5.x через PIV slot `9a` (Authentication), с обязательной сменой:

- PIV PIN
- PIV PUK
- PIV Management Key
- созданием и записью X.509 certificate в slot `9a`

> Важно: PIV, OpenPGP, FIDO2, OATH и OTP — независимые приложения внутри YubiKey.  
> `ykman piv reset` стирает **только PIV**, но всё содержимое PIV при этом будет удалено.

---

## 1. Проверить YubiKey

```bash
ykman info
```

Пример:

```text
Device type: YubiKey 5 NFC
Serial number: 12345678
Firmware version: 5.7.1
PIV: Enabled
```

Для RSA4096 в PIV нужен YubiKey с поддержкой RSA4096, например firmware 5.7.x.

---

## 2. Проверить исходный SSH key

Предположим, исходный ключ:

```text
~/.ssh/id_rsa
```

Посмотреть fingerprint:

```bash
ssh-keygen -lf ~/.ssh/id_rsa.pub
```

Если private key находится в OpenSSH format:

```bash
head -1 ~/.ssh/id_rsa
```

обычно будет:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
```

---

## 3. Сделать временную PEM-копию

Не трогаем оригинал:

```bash
cp ~/.ssh/id_rsa /dev/shm/id_rsa_yubikey.pem
chmod 600 /dev/shm/id_rsa_yubikey.pem
```

Конвертируем копию в PEM:

```bash
ssh-keygen -p -m PEM -f /dev/shm/id_rsa_yubikey.pem
```

Можно оставить тот же passphrase.

Проверяем RSA exponent:

```bash
openssl rsa   -in /dev/shm/id_rsa_yubikey.pem   -text -noout   | grep publicExponent
```

Для YubiKey PIV должно быть:

```text
publicExponent: 65537 (0x10001)
```

Если exponent другой, например:

```text
publicExponent: 35 (0x23)
```

этот RSA keypair в PIV импортировать нельзя без смены SSH identity. Нужно создать новый RSA key с `e=65537`.

---

## 4. Если PIV нужно очистить

Сначала проверить текущее состояние:

```bash
ykman piv info
```

Если PIV содержит старые нужные keys/certificates — **reset делать нельзя**.

Если PIV можно полностью очистить:

```bash
ykman piv reset
```

После reset заводские значения:

```text
PIN:            123456
PUK:            12345678
Management Key: default
```

---

## 5. ОБЯЗАТЕЛЬНО сменить PIV PIN

```bash
ykman piv access change-pin
```

После reset текущий PIN:

```text
123456
```

Проверь:

```bash
ykman piv info
```

Warning `Using default PIN!` должен исчезнуть.

---

## 6. ОБЯЗАТЕЛЬНО сменить PIV PUK

```bash
ykman piv access change-puk
```

После reset текущий PUK:

```text
12345678
```

PUK нужен для разблокировки PIN. Оставлять default PUK нельзя: человек с физическим доступом к YubiKey мог бы заблокировать PIN и затем установить новый PIN через известный default PUK.

После смены:

```bash
ykman piv info
```

Warning `Using default PUK!` должен исчезнуть.

---

## 7. ОБЯЗАТЕЛЬНО сменить PIV Management Key

Удобный вариант: сгенерировать случайный Management Key и хранить его на самом YubiKey, защищённым PIV PIN:

```bash
ykman piv access change-management-key --generate --protect
```

После этого:

```bash
ykman piv info
```

должно показывать:

```text
Management key is stored on the YubiKey, protected by PIN.
```

Смена Management Key **не стирает** уже записанные PIV keys/certificates.

---

## 8. Импортировать SSH private key в PIV slot 9a

Slot `9a` — стандартный PIV Authentication slot.

```bash
ykman piv keys import   --pin-policy ONCE   --touch-policy ALWAYS   9a /dev/shm/id_rsa_yubikey.pem
```

Что означают policy:

```text
PIN policy ONCE     PIN требуется один раз на PIV session
touch policy ALWAYS физический touch требуется для каждой private-key операции
```

Проверить:

```bash
ykman piv info
```

После импорта должно быть:

```text
Slot 9A (AUTHENTICATION):
  Private key type: RSA4096
```

---

## 9. Создать public key в PEM

Из исходного private key:

```bash
openssl pkey   -in /dev/shm/id_rsa_yubikey.pem   -pubout   -out /dev/shm/id_rsa_yubikey-public.pem
```

---

## 10. ОБЯЗАТЕЛЬНО создать и записать X.509 certificate

PKCS#11/PIV middleware использует certificate в том же slot.

Создаём self-signed certificate прямо в `9a`:

```bash
ykman piv certificates generate   --subject "CN=SSH key"   9a /dev/shm/id_rsa_yubikey-public.pem
```

Проверяем:

```bash
ykman piv info
```

Пример:

```text
Slot 9A (AUTHENTICATION):
  Private key type: RSA4096
  Public key type:  RSA4096
  Subject DN:       CN=SSH key
  Issuer DN:        CN=SSH key
```

---

## 11. Проверить SSH public key из YubiKey

Через Yubico PKCS#11 provider:

```bash
ssh-keygen -D /usr/lib/x86_64-linux-gnu/libykcs11.so   | head -1   | ssh-keygen -lf -
```

Сравнить с исходным:

```bash
ssh-keygen -lf ~/.ssh/id_rsa.pub
```

Fingerprint должен совпасть **в точности**.

---

## 12. Проверить реальный SSH login

Например:

```bash
ssh -I /usr/lib/x86_64-linux-gnu/libykcs11.so user@example-host
```

Ожидаемо:

```text
Enter PIN for 'YubiKey PIV #12345678':
```

При `touch-policy ALWAYS` потребуется физический touch YubiKey.

---

## 13. Удобный SSH config

Чтобы не указывать `-I` каждый раз:

```sshconfig
Host *
    PKCS11Provider /usr/lib/x86_64-linux-gnu/libykcs11.so
```

Либо только для нужных hosts:

```sshconfig
Host work-*
    PKCS11Provider /usr/lib/x86_64-linux-gnu/libykcs11.so
```

Тогда достаточно:

```bash
ssh work-server
```

---

## 14. Если нужен тот же SSH identity на нескольких YubiKey

Один и тот же исходный private key можно импортировать в несколько YubiKey.

Для каждого нового YubiKey повторить:

1. проверить serial через `ykman info`
2. при необходимости сделать `ykman piv reset`
3. сменить PIN
4. сменить PUK
5. сменить Management Key
6. импортировать тот же private key в `9a`
7. создать X.509 certificate в `9a`
8. проверить fingerprint
9. проверить реальный SSH login

Не генерировать keypair внутри первого YubiKey, если требуется несколько одинаковых токенов: private key, созданный внутри PIV, обратно не экспортируется.

---

## 15. Cleanup временных файлов

После успешной проверки:

```bash
rm -f   /dev/shm/id_rsa_yubikey.pem   /dev/shm/id_rsa_yubikey-public.pem
```

Исходный private key/master backup хранить отдельно в надёжно зашифрованном виде.

---

## Короткий чек-лист

```text
[ ] YubiKey serial проверен
[ ] PIV PIN сменён
[ ] PIV PUK сменён
[ ] PIV Management Key сменён
[ ] RSA exponent = 65537
[ ] private key импортирован в 9a
[ ] X.509 certificate создан в 9a
[ ] fingerprint совпадает с исходным SSH key
[ ] реальный SSH login работает
[ ] временные PEM-файлы удалены
[ ] master private key сохранён offline/encrypted
```
