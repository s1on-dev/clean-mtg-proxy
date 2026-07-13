# Архитектура

```text
Telegram client
  |
  | tg://proxy or https://t.me/proxy link
  v
VPS firewall: TCP/443 or selected port
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

Дополнительный HTTP disguise-профиль, если включен:

```text
Browser or scanner
  |
  | HTTP/80 or selected disguise port
  v
Nginx
  |
  v
/var/www/mtg-disguise/index.html
```

## Компоненты

- `install.sh` ставит и настраивает сервис.
- `/etc/mtg/config.toml` хранит активный secret, bind, network и defense-настройки.
- `/etc/mtg/secrets.tsv` хранит сохраненные secret для ротации.
- `/etc/mtg/allowlist.netset` хранит CIDR-список разрешенных клиентов, если включен allowlist.
- `mtg.service` запускает Docker-контейнер в foreground-режиме.
- `mtgctl` дает короткие команды для статуса, логов, doctor, ссылки, QR, speedtest и BBR/NAT.
- `.github/workflows/ci.yml` проверяет `install.sh` через `bash -n` и ShellCheck.

## Почему Docker + systemd

Docker дает переносимость между VPS-образами и не требует скачивать отдельный
бинарник под архитектуру. Systemd отвечает за автозапуск, перезапуск и единый
интерфейс логов.

Контейнер слушает внутренний порт `3128`, наружу публикуется выбранный порт,
обычно `443/tcp`.

## Secret-Модель

`nineseconds/mtg` v2 поддерживает один активный secret. Поэтому установщик не
делает несколько одновременно активных ключей. Вместо этого он хранит список
сохраненных secret и быстро переключает активный:

1. выбранный secret пишется в `/etc/mtg/config.toml`;
2. systemd unit и helper обновляются;
3. `mtg.service` перезапускается;
4. новая ссылка и QR-код выводятся через `mtgctl access`.

Такой подход сохраняет совместимость с upstream `mtg` и дает нормальную ротацию
доступа без смены backend.

## Безопасность И Устойчивость

- FakeTLS secret генерируется через `mtg generate-secret --hex`.
- `anti-replay` включен.
- Blocklist включен через `firehol_abusers_1d`, чтобы не использовать слишком агрессивный `firehol_level1`.
- Optional allowlist включается через native `[defense.allowlist]`.
- Конфиг и secret-store хранятся с правами `0600`.
- Docker-логи ограничены ротацией `10m x 5`.
- `mtg doctor` запускается во время установки и доступен после нее.
- QR-код генерируется локально через `qrencode`, без отправки ссылки третьим сервисам.

## Nginx Disguise

Disguise-профиль ставит простую HTTP-страницу на отдельный порт, обычно `80`.
Он нужен как тихий decoy для обычного HTTP-сканирования IP.

Он не подменяет SNI-router и не делит один HTTPS-порт с MTProto. Если нужен
полноценный HTTPS/SNI-мультиплексор, лучше добавлять отдельный HAProxy/SNI-router
профиль, чтобы не усложнять чистый базовый установщик.

## Скорость

MTProxy не ускоряет Telegram сам по себе. На скорость сильнее всего влияют:

- география VPS относительно пользователей;
- качество сети провайдера;
- packet loss и jitter;
- доступность Telegram DC с VPS;
- внешний cloud firewall;
- DPI-ограничения;
- TCP congestion control и NAT/cloud edge.

`mtgctl speedtest` быстро проверяет Telegram DC и исходящую HTTPS-скорость VPS.
`mtgctl bbr-nat` показывает BBR/NAT-состояние и подсказывает команды для
включения BBR, но не меняет kernel-параметры автоматически.
