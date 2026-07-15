# Clean MTProto Proxy

Чистый установщик MTProto-прокси для Telegram без рекламы. Проект использует
актуальный `telemt` в режиме Secure (`dd`) и запускает его через Docker + systemd.

Главное отличие от старых версий проекта: FakeTLS, `sslip.io`, domain fronting и
Nginx больше не участвуют в передаче сообщений. Это устраняет петлю
`VPS:443 -> fronting domain -> VPS:443`, из-за которой Telegram показывал
«подключён», но сообщения не отправлялись.

## Возможности

- Secure MTProto с обязательным префиксом `dd`;
- несколько одновременно активных секретов;
- меню установки и управления;
- systemd-сервис с Docker-контейнером;
- локальный firewall для `ufw` и `firewalld`;
- readiness-проверка канала до Telegram перед успешным завершением установки;
- ссылки `tg://` и `https://t.me`, локальный QR-код;
- логи с ротацией;
- диагностика Telegram DC, BBR/NAT и базовый speed test;
- обновление, перезапуск и полное удаление.

Реклама не настраивается: `ad_tag` отсутствует в конфигурации.

## Установка

На Ubuntu/Debian VPS:

```bash
cd /root
curl -4 --tlsv1.2 -fsSL \
  -o install.sh \
  https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

Откроется меню. Выберите `1) Install / update proxy`.

Тихая установка без меню:

```bash
sudo ./install.sh --port 443 --server 144.31.188.19
```

`--server` можно не указывать: установщик попробует определить публичный IPv4
автоматически.

Если `raw.githubusercontent.com` недоступен через `curl`, используйте:

```bash
wget -4 -O install.sh \
  https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## Миграция со старого mtg

Повторная установка автоматически:

1. останавливает и отключает старый `mtg.service`;
2. удаляет старый контейнер `mtg-proxy`;
3. останавливает альтернативный `mtprotoproxy`, сохраняя контейнер для отката;
4. сохраняет `/etc/mtg` как резервную копию;
5. создаёт новый `telemt-proxy.service`;
6. генерирует новый Secure-секрет;
7. ждёт readiness и только затем показывает новую ссылку.

Старые `ee`/FakeTLS-ссылки после миграции использовать нельзя. В Telegram нужно
удалить старую запись прокси и добавить новую ссылку с `secret=dd...`.

## Меню

```text
1) Install / update proxy
2) Show status
3) Show proxy links + QR
4) Show logs
5) Run doctor
6) Add secret
7) Revoke secret
8) Regenerate secret
9) Run speed test
10) Run BBR/NAT diagnostics
11) Restart proxy
12) Update container image
13) Remove proxy
0) Exit
```

Telemt поддерживает несколько секретов одновременно. Поэтому добавление нового
секрета не отключает старых пользователей. Последний оставшийся секрет удалить
нельзя, но его можно перегенерировать.

## Управление

```bash
sudo mtgctl status
sudo mtgctl doctor
sudo mtgctl access
sudo mtgctl qr
sudo mtgctl logs
sudo mtgctl follow
sudo mtgctl users
sudo mtgctl speedtest
sudo mtgctl bbr-nat
sudo mtgctl restart
sudo mtgctl update
```

Управление секретами:

```bash
sudo mtgctl add family
sudo mtgctl add phone 0123456789abcdef0123456789abcdef
sudo mtgctl regenerate family
sudo mtgctl revoke phone
```

## Проверка работоспособности

```bash
sudo mtgctl doctor
```

Успешная проверка подтверждает:

- активный systemd-сервис;
- запущенный Docker-контейнер;
- Telemt liveness;
- Telemt readiness, включая готовность upstream-маршрута;
- локальный listener на публичном порту;
- readiness рабочего upstream-маршрута; прямые TCP-пробы Telegram DC 1-5
  выводятся дополнительно и не отменяют готовность Middle-End.

После установки также полезно проверить:

```bash
sudo ss -ltnp | grep ':443'
sudo docker logs --tail 100 telemt-proxy
```

Нормальная ссылка выглядит так:

```text
tg://proxy?server=144.31.188.19&port=443&secret=dd<32-hex-secret>
```

## Параметры

```bash
sudo ./install.sh --port 443
sudo ./install.sh --server 144.31.188.19
sudo ./install.sh --secret-label family
sudo ./install.sh --secret 0123456789abcdef0123456789abcdef
sudo ./install.sh --tag 3.4.23
sudo ./install.sh --prefer-ipv6
sudo ./install.sh --direct
sudo ./install.sh --middle-proxy
sudo ./install.sh --enable-bbr
sudo ./install.sh --bbr-nat-check
sudo ./install.sh --speedtest
sudo ./install.sh --skip-firewall
sudo ./install.sh --iptables-fallback
sudo ./install.sh --no-strict-doctor
```

По умолчанию включён Direct-DC: он устраняет лишний промежуточный маршрут и обычно
быстрее передаёт медиа. `--middle-proxy` включает Telegram Middle-End с Direct-DC
fallback, если такой маршрут лучше работает у конкретного VPS-провайдера.
Флаг `--enable-bbr` включает BBR и очередь `fq`; это может повысить скорость на
каналах с потерями, но не отменяет ограничение пропускной способности VPS.

Старые параметры `--domain`, `--fronting-host`, `--disable-blocklist` и
`--disable-nginx-disguise` принимаются для совместимости, но игнорируются.

## Firewall

Установщик открывает выбранный TCP-порт в активном `ufw` или `firewalld`.
Если firewall управляется в панели VPS-провайдера, откройте там тот же порт:

```text
Protocol: TCP
Port:     443
Source:   0.0.0.0/0
```

`--iptables-fallback` создаёт только временное правило, которое может исчезнуть
после перезагрузки.

## Файлы

```text
/etc/clean-mtg-proxy/config.toml   Telemt config (root:65532, mode 0640)
/etc/clean-mtg-proxy/users.tsv    secrets (mode 0600)
/etc/clean-mtg-proxy/install.env  installer state (mode 0600)
/etc/systemd/system/telemt-proxy.service
/usr/local/bin/mtgctl
```

Docker-образ закреплён на `ghcr.io/telemt/telemt:3.4.23`. Образ multi-arch и
поддерживает `amd64` и `arm64`.

## Удаление

Оставить конфигурацию:

```bash
sudo mtgctl uninstall
```

Удалить также секреты и конфигурацию:

```bash
sudo mtgctl uninstall --purge
```

## Разработка

Локальные проверки:

```bash
bash -n install.sh
bash tests/test_install.sh
shellcheck install.sh tests/test_install.sh
```

GitHub Actions дополнительно извлекает встроенный `mtgctl`, проверяет его через
`bash -n` и ShellCheck, а также разбирает сгенерированный TOML через Python
`tomllib`.
