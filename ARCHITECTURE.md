# Архитектура

```text
Telegram client
  |
  | MTProto proxy link: tg://proxy?server=VPS_IP&port=443&secret=...
  v
VPS firewall: TCP/443
  |
  v
systemd: mtg.service
  |
  v
Docker container: mtg-proxy
  |
  | /etc/mtg/config.toml mounted as /config.toml
  v
nineseconds/mtg
  |
  v
Telegram data centers
```

## Компоненты

- `install.sh` ставит и настраивает сервис.
- `/etc/mtg/config.toml` хранит secret, bind, network и defense-настройки.
- `mtg.service` запускает Docker-контейнер в foreground-режиме, поэтому логи видны через `journalctl`.
- `mtgctl` даёт короткие команды для статуса, логов, doctor, access-ссылок и speedtest.

## Почему Docker + systemd

Docker даёт переносимость между VPS-образами и не требует скачивать отдельный бинарник под архитектуру. Systemd отвечает за автозапуск, перезапуск и единый интерфейс логов.

Контейнер слушает внутренний порт `3128`, а наружу публикуется выбранный порт, обычно `443/tcp`.

## Безопасность и устойчивость

- FakeTLS secret генерируется через `mtg generate-secret --hex`.
- `anti-replay` включён.
- Blocklist включён через `firehol_abusers_1d`, чтобы не использовать слишком агрессивный `firehol_level1`.
- Docker-логи ограничены ротацией `10m x 5`.
- Конфиг хранится с правами `0600`.
- `mtg doctor` запускается во время установки и доступен после неё.

## Скорость

MTProxy не ускоряет Telegram сам по себе. Он помогает, когда прямой маршрут до Telegram блокируется, режется или плохо маршрутизируется.

На скорость сильнее всего влияют:

- география VPS относительно пользователей;
- качество сети провайдера;
- packet loss и jitter;
- доступность Telegram DC с VPS;
- внешний cloud firewall и отсутствие DPI-ограничений.

`mtgctl speedtest` проверяет базовую доступность Telegram DC и исходящую HTTPS-скорость VPS. Это быстрая диагностика маршрута, не лабораторный benchmark клиента Telegram.
