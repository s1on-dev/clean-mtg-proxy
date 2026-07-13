# Clean MTG Proxy Installer

Чистый установщик MTProto-прокси для Telegram на базе `nineseconds/mtg` v2.
По умолчанию используется закрепленный Docker-тег `2.2.8`.

Цель проекта: один понятный скрипт для любого обычного Linux VPS без рекламы,
с нормальным Docker/systemd-запуском, firewall, `mtg doctor`, логами, QR-кодом,
speedtest, BBR/NAT-диагностикой и безопасной ротацией secret.

## Быстрая установка

Стабильная команда для релиза `v1.0.3`:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/v1.0.3/install.sh
sudo bash install.sh
```

Последняя версия из `main`:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh
sudo bash install.sh
```

Быстрая установка без меню:

```bash
curl -fsSL https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/v1.0.3/install.sh \
  | sudo bash -s -- --domain proxy.your-domain.com --port 443
```

Замените `proxy.your-domain.com` на домен, которым вы управляете. Он должен
резолвиться A-записью в публичный IPv4 вашего VPS. Не используйте
`example.com`, `digitalocean.com`, `hetzner.com` или другие чужие домены.

`--domain` нужен для FakeTLS-secret. Самый надежный вариант - домен, которым вы
управляете, с A-записью на публичный IPv4 VPS и реальным HTTPS-сайтом на `443`.
Случайный CDN/сайт может работать хуже: `mtg doctor` покажет SNI-DNS mismatch,
если домен резолвится не в IP вашего VPS.

## Меню

При запуске `sudo bash install.sh` без параметров откроется меню:

- установка или обновление прокси;
- изменение домена, порта, Docker-тега, IP-режима, DNS и лимитов;
- вывод `tg://proxy` ссылки и QR-кода;
- статус, логи, `mtg doctor`, speedtest;
- BBR/NAT-диагностика;
- Add / switch secret;
- Revoke secret;
- Regenerate active secret;
- настройка Nginx disguise и IP allowlist;
- перезапуск и удаление.

Важно: upstream `mtg` v2 поддерживает один активный secret. Установщик хранит
список сохраненных secret в `/etc/mtg/secrets.tsv`, но в `config.toml` активным
становится только один. Это сделано для совместимости с чистым `nineseconds/mtg`.

## Управление

```bash
sudo mtgctl status
sudo mtgctl logs
sudo mtgctl follow
sudo mtgctl doctor
sudo mtgctl access
sudo mtgctl qr
sudo mtgctl speedtest
sudo mtgctl bbr-nat
sudo mtgctl restart
sudo mtgctl uninstall
```

`sudo mtgctl access` выводит только ссылку. `sudo mtgctl qr` выводит ссылку и
локальный QR-код. Если `qrencode` недоступен в репозиториях ОС, ссылка все равно
будет показана, а QR можно включить позже:

Ссылка строится с HEX-secret, это наиболее совместимый формат для Telegram.

```bash
sudo apt-get install -y qrencode
sudo mtgctl qr
```

## Полезные флаги

```bash
sudo bash install.sh --domain proxy.your-domain.com --port 443
sudo bash install.sh --domain proxy.your-domain.com --prefer-ip prefer-ipv4 --concurrency 16384
sudo bash install.sh --domain proxy.your-domain.com --secret-label family
sudo bash install.sh --domain proxy.your-domain.com --allowlist "203.0.113.10/32,198.51.100.0/24"
sudo bash install.sh --domain proxy.your-domain.com --nginx-disguise --disguise-port 80
sudo bash install.sh --domain proxy.your-domain.com --disable-nginx-disguise
sudo bash install.sh --domain 144.31.188.19.sslip.io --fronting-host www.cloudflare.com --disable-nginx-disguise
sudo bash install.sh --domain proxy.your-domain.com --bbr-nat-check
sudo bash install.sh --domain proxy.your-domain.com --enable-blocklist
sudo bash install.sh --domain proxy.your-domain.com --blocklist https://iplists.firehol.org/files/firehol_abusers_1d.netset
sudo bash install.sh --domain proxy.your-domain.com --strict-doctor
sudo bash install.sh --domain proxy.your-domain.com --skip-firewall
sudo bash install.sh --domain proxy.your-domain.com --skip-docker-install
```

## Nginx Disguise И Allowlist

Nginx disguise профиль ставит тихую HTTP-страницу на отдельный порт, обычно
`80/tcp`. Он не занимает порт MTProto-прокси, поэтому не конфликтует с `443/tcp`.
Для совместного HTTPS/SNI-мультиплексирования нужен отдельный SNI-router или
HAProxy-профиль, это сознательно не включено в чистый установщик.

IP allowlist включается внутри `mtg` через `[defense.allowlist]` и файл
`/etc/mtg/allowlist.netset`. Клиенты вне указанных CIDR будут отклоняться.

Если для теста используется `sslip.io` или другой домен, который резолвится в
тот же IP, где слушает `mtg`, добавьте `--fronting-host HOST`. Иначе
отклоненный/probe-трафик может уходить обратно в `mtg:443` и создавать
`cannot dial to the fronting domain`.

## Логи

```bash
sudo journalctl -u mtg.service -n 100 --no-pager
sudo journalctl -u mtg.service -f
```

Короткий вариант:

```bash
sudo mtgctl logs
sudo mtgctl follow
```

Docker-логи ограничены ротацией `10m x 5`, чтобы VPS не заполнялся логами.

## Firewall

Скрипт открывает TCP-порт прокси в активном `ufw` или `firewalld`. Если включен
Nginx disguise, он также открывает HTTP-порт disguise-профиля.

Если у VPS есть внешний cloud firewall в панели провайдера, откройте там тот же
порт, обычно `443/tcp`.

Для временного iptables-правила можно использовать:

```bash
sudo bash install.sh --domain proxy.your-domain.com --iptables-fallback
```

## Blocklist

Blocklist по умолчанию выключен. Его можно включить через меню или флаг
`--enable-blocklist`. Флаг `--blocklist URL` задает FireHOL-compatible список и
тоже включает blocklist.

Если клиентский IP попадает в blocklist, `mtg` отправляет подключение в
domain-fronting fallback. Это может выглядеть как "подключено, но сообщения не
отправляются", поэтому для личного прокси безопаснее начинать с выключенного
blocklist и включать его только осознанно.

## Скорость И Диагностика

`sudo mtgctl speedtest` проверяет:

- `mtg doctor`;
- TCP-доступность нескольких Telegram DC на `443`;
- базовую HTTPS-скорость исходящего канала VPS через Cloudflare 25 MB.

`sudo mtgctl bbr-nat` показывает:

- текущий TCP congestion control;
- включен ли BBR;
- локальный и публичный IPv4/IPv6;
- возможный NAT/cloud edge;
- локальные listener-порты.

MTProxy не ускоряет Telegram сам по себе. Он помогает, когда прямой маршрут до
Telegram блокируется, режется или плохо маршрутизируется.

## Удаление

Оставить конфиг:

```bash
sudo mtgctl uninstall
```

Удалить также `/etc/mtg`:

```bash
sudo mtgctl uninstall --purge
```

## Безопасный Запуск

Перед запуском на сервере можно скачать и посмотреть скрипт:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/v1.0.3/install.sh
less install.sh
sudo bash install.sh
```

CI проверяет `install.sh`, встроенный `mtgctl` helper и ShellCheck.

Архитектура описана в [ARCHITECTURE.md](ARCHITECTURE.md).
