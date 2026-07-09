# Clean MTG Proxy Installer

Чистый установщик MTProto-прокси для Telegram на базе `nineseconds/mtg` v2. По умолчанию используется закреплённый Docker-тег `2.2.8`.

Цель проекта: один понятный скрипт для VPS без рекламы, с нормальным Docker/systemd-запуском, firewall, `mtg doctor`, логами и базовым тестом скорости.

## Что ставится

- Docker, если его ещё нет.
- `/etc/mtg/config.toml` с FakeTLS-secret и безопасными дефолтами.
- `systemd`-service `mtg.service`.
- Docker-контейнер `mtg-proxy`.
- Утилита управления `mtgctl`.
- Правило firewall для TCP-порта, если активен `ufw` или `firewalld`.

Схема работы описана в [ARCHITECTURE.md](ARCHITECTURE.md).

## Быстрая установка

После публикации репозитория на GitHub команда будет такой:

Интерактивное меню на VPS:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh
sudo bash install.sh
```

В меню будут пункты:

- установка или обновление прокси;
- изменение домена, порта, Docker-тега, IP-режима, DNS и лимитов;
- вывод ссылки `tg://proxy` / `https://t.me/proxy`;
- статус, логи, `mtg doctor`, speedtest и перезапуск;
- удаление прокси с возможностью оставить или удалить `/etc/mtg`.

Быстрая установка без меню:

```bash
curl -fsSL https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh \
  | sudo bash -s -- --domain digitalocean.com --port 443
```

Локальный запуск из клона:

```bash
sudo bash install.sh
sudo bash install.sh --domain digitalocean.com --port 443
```

`--domain` нужен для FakeTLS-secret. Лучше выбирать домен осмысленно: не `google.com` на случайном VPS, а домен, который выглядит логично для вашего хостинга/маршрута. Если есть сомнения, начните с домена провайдера VPS и проверьте результат через `sudo mtgctl doctor`.

## Управление

```bash
sudo mtgctl status
sudo mtgctl logs
sudo mtgctl follow
sudo mtgctl doctor
sudo mtgctl access
sudo mtgctl speedtest
sudo mtgctl restart
sudo mtgctl uninstall
```

`sudo mtgctl access` выводит `tg://proxy` и `https://t.me/proxy` ссылки.

## Полезные флаги установщика

```bash
sudo bash install.sh --domain digitalocean.com --port 443
sudo bash install.sh --domain hetzner.com --prefer-ip prefer-ipv4 --concurrency 16384
sudo bash install.sh --domain example.com --tag 2.2.8
sudo bash install.sh --domain example.com --strict-doctor
sudo bash install.sh --domain example.com --skip-firewall
sudo bash install.sh --domain example.com --skip-docker-install
```

По умолчанию `mtg doctor` не останавливает установку, а показывает предупреждение. Если нужен строгий режим, используйте `--strict-doctor`.

## Логи

Основные логи:

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

Скрипт открывает TCP-порт в активном `ufw` или `firewalld`.

Если на VPS есть внешний firewall в панели провайдера, откройте там тот же порт, обычно `443/tcp`.

Если `ufw`/`firewalld` не активны, скрипт ничего жёстко не меняет. Для временного iptables-правила можно использовать:

```bash
sudo bash install.sh --domain digitalocean.com --iptables-fallback
```

## Скорость

`sudo mtgctl speedtest` проверяет:

- `mtg doctor`;
- TCP-доступность нескольких Telegram DC на `443`;
- базовую HTTPS-скорость исходящего канала VPS через Cloudflare 25 MB.

Это не полноценный тест скорости внутри клиента Telegram, но он быстро показывает плохой маршрут, потери или слабый VPS.

## Удаление

Оставить конфиг:

```bash
sudo mtgctl uninstall
```

Удалить также `/etc/mtg`:

```bash
sudo mtgctl uninstall --purge
```

## Публикация на GitHub

```bash
git init
git add .
git commit -m "Initial clean mtg proxy installer"
gh repo create clean-mtg-proxy --public --source . --remote origin --push
```

После публикации команда установки уже готова для `s1on-dev/clean-mtg-proxy`.

## Безопасный запуск

Перед запуском на сервере можно скачать и посмотреть скрипт:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/s1on-dev/clean-mtg-proxy/main/install.sh
less install.sh
sudo bash install.sh --domain digitalocean.com
```

Так проще убедиться, что на VPS запускается именно тот код, который вы ожидаете.
