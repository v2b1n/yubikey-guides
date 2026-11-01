# HowTo: перенос существующего OpenPGP-ключа на YubiKey

Актуальный рабочий порядок:

```text
reset
→ key-attr RSA4096
→ kdf-setup
→ keytocard primary
→ keytocard encryption
→ touch policies
→ функциональные тесты
→ сменить User PIN
→ сменить Admin PIN
```

Логика: все административные операции выполняются на заводских PIN'ах, а финальные длинные PIN'ы задаются только в самом конце.

## 1. Исходный backup

Нужен **полный backup `~/.gnupg`, сделанный до первого `keytocard`**, когда private key material ещё находился на диске.

Пример:

```bash
tar -C "$HOME" -czf gnupg-backup.tar.gz .gnupg
```

После переноса ключей на YubiKey обычный `~/.gnupg` содержит card stubs и уже не является полной master-копией private keys.

## 2. Подготовить временный GNUPGHOME

```bash
export YKHOME=/dev/shm/yk-gnupg

rm -rf "$YKHOME"
mkdir -m 700 "$YKHOME"
```

Распаковать туда исходный pre-YubiKey backup.

Если backup содержит `.gnupg`:

```bash
tar -C /dev/shm -xzf gnupg-backup.tar.gz
cp -a /dev/shm/.gnupg/. "$YKHOME"/
rm -rf /dev/shm/.gnupg
```

Для работы через PC/SC:

```bash
cat > "$YKHOME/scdaemon.conf" <<'EOF'
disable-ccid
pcsc-shared
EOF

chmod 600 "$YKHOME/scdaemon.conf"
```

Перезапустить agent/scdaemon именно для этого home:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

Проверить private material:

```bash
gpg --homedir "$YKHOME"   --list-secret-keys   --with-subkey-fingerprint   --keyid-format LONG
```

Перед переносом должно быть:

```text
sec  ... [SC]
ssb  ... [E]
```

без `>`.

## 3. Проверить нужный YubiKey

```bash
ykman info
```

Убедиться в нужном serial number.

## 4. При необходимости reset только OpenPGP applet

```bash
ykman openpgp reset
```

Это сбрасывает только OpenPGP applet и не трогает PIV/FIDO/OATH/OTP.

После reset заводские credentials:

```text
User PIN:  123456
Admin PIN: 12345678
```

## 5. Выставить RSA4096 attributes

```bash
gpg --card-edit
```

Внутри:

```text
admin
key-attr
```

Выставить:

```text
Signature      RSA 4096
Encryption     RSA 4096
Authentication RSA 4096
```

Authentication slot может оставаться пустым.

## 6. Включить OpenPGP KDF

Пока ключи ещё не загружены:

```bash
gpg --card-edit
```

Внутри:

```text
admin
kdf-setup
```

Проверить:

```bash
gpg --card-status
```

Ожидаемо:

```text
KDF setting ......: on
PIN retry counter : 3 0 3
```

После `kdf-setup` используются заводские PIN'ы:

```text
User PIN:  123456
Admin PIN: 12345678
```

Reset Code можно не устанавливать.

## 7. Убедиться, что временный GNUPGHOME видит карту

```bash
gpg --homedir "$YKHOME" --card-status
```

Если:

```text
gpg: selecting card failed: No such device
```

проверить `$YKHOME/scdaemon.conf` и перезапустить:

```bash
gpgconf --homedir "$YKHOME" --kill scdaemon
gpgconf --homedir "$YKHOME" --kill gpg-agent
```

## 8. Перенести primary `[SC]` в Signature slot

Пример fingerprint:

```text
7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

```bash
gpg --homedir "$YKHOME"   --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Внутри:

```text
keytocard
```

Подтвердить перенос primary key и выбрать:

```text
1 = Signature key
```

Текущий Admin PIN:

```text
12345678
```

Затем:

```text
save
```

## 9. Перенести encryption subkey `[E]`

Открыть ключ заново:

```bash
gpg --homedir "$YKHOME"   --edit-key 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901
```

Выбрать encryption subkey:

```text
key 1
```

Убедиться, что `*` стоит на subkey с usage `[E]`.

Далее:

```text
keytocard
```

Выбрать:

```text
2 = Encryption key
```

и:

```text
save
```

## 10. Включить touch policy

```bash
ykman openpgp keys set-touch SIG on
ykman openpgp keys set-touch ENC on
```

Проверить:

```bash
gpg --card-status
```

Ожидаемо:

```text
UIF setting ......: Sign=on Decrypt=on Auth=off
```

## 11. Проверить состояние карты

Лучше через тот же временный GNUPGHOME:

```bash
gpg --homedir "$YKHOME" --card-status
```

Пример:

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

## 12. Функциональный тест до финальной смены PIN'ов

Подпись:

```bash
date > /tmp/pgp-test.txt

gpg --homedir "$YKHOME"   --detach-sign /tmp/pgp-test.txt
```

Расшифрование:

```bash
echo "decrypt test" > /tmp/pgp-plain.txt

gpg --homedir "$YKHOME"   --recipient 7A91C4D8E2F6B1034C5D8899A12B34C56D78E901   --encrypt /tmp/pgp-plain.txt

gpg --homedir "$YKHOME"   --decrypt /tmp/pgp-plain.txt.gpg
```

Обе операции должны работать и требовать touch.

## 13. Только теперь сменить User PIN

```bash
gpg --card-edit
```

Внутри:

```text
admin
passwd
1
```

Текущий User PIN:

```text
123456
```

Задать финальный длинный буквенно-цифровой User PIN.

## 14. Затем сменить Admin PIN

В том же меню:

```text
3
```

Текущий Admin PIN:

```text
12345678
```

Задать отдельный длинный Admin PIN.

Важно: Admin PIN нельзя восстановить через Reset Code. После блокировки Admin PIN потребуется reset OpenPGP applet и повторный перенос ключей из backup.

## 15. Reset Code — опционально

Можно задать через:

```text
gpg --card-edit
admin
passwd
4
```

Но он нужен только для восстановления User PIN.

Он:

```text
НЕ восстанавливает Admin PIN
НЕ обязателен
```

Нормальное состояние без Reset Code:

```text
PIN retry counter : 3 0 3
```

## 16. Финальная проверка

```bash
gpg --card-status
```

Ожидаемо:

```text
PIN retry counter : 3 0 3
KDF setting ......: on
UIF setting ......: Sign=on Decrypt=on Auth=off
```

Проверить ещё раз подпись и decrypt уже с финальным User PIN.

## 17. Cleanup

После успешного теста:

```bash
rm -rf "$YKHOME"
```

## 18. Для второго/третьего YubiKey

Повторять процесс **снова из исходного pre-YubiKey backup**, а не из временного keyring, который уже превратился в card stubs.

Рабочий порядок:

```text
reset
→ key-attr RSA4096
→ kdf-setup
→ keytocard primary
→ keytocard encryption
→ touch SIG/ENC
→ sign/decrypt test
→ сменить User PIN
→ сменить Admin PIN
→ финальный test
```

## Короткий чек-лист

```text
[ ] serial YubiKey проверен
[ ] OpenPGP reset выполнен при необходимости
[ ] RSA4096 attributes выставлены
[ ] KDF включён
[ ] temporary GNUPGHOME видит карту
[ ] primary [SC] перенесён в Signature slot
[ ] encryption [E] перенесён в Encryption slot
[ ] touch SIG включён
[ ] touch ENC включён
[ ] sign test работает
[ ] decrypt test работает
[ ] User PIN сменён на финальный
[ ] Admin PIN сменён на финальный
[ ] PIN retry counter = 3 0 3
[ ] KDF = on
[ ] UIF = Sign=on Decrypt=on Auth=off
[ ] temporary GNUPGHOME удалён
```
