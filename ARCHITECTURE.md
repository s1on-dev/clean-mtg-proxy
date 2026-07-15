# Архитектура

```text
Telegram client
  |
  | Secure MTProto, secret prefix dd
  v
VPS/cloud firewall: TCP/443 (или выбранный порт)
  |
  v
Docker publish: public PORT -> container TCP/3128
  |
  v
telemt-proxy container
  |
  +-- Telegram Middle-End
  |
  `-- Direct-DC fallback
        |
        v
      Telegram DC 1-5
```

В этой схеме нет FakeTLS-домена, SNI-DNS проверки, `sslip.io`, Nginx и
domain-fronting backend. Прокси не пытается подключаться обратно к собственному
публичному порту.

## Компоненты

- `install.sh` устанавливает зависимости, Docker, конфигурацию и systemd unit.
- `telemt-proxy.service` запускает контейнер в foreground и отвечает за автозапуск.
- `ghcr.io/telemt/telemt:3.4.23` обрабатывает MTProto-трафик.
- `/etc/clean-mtg-proxy/config.toml` содержит Secure-only конфигурацию.
- `/etc/clean-mtg-proxy/users.tsv` хранит несколько активных секретов.
- `mtgctl` управляет сервисом, ссылками, ключами и диагностикой.

## Режим транспорта

Конфигурация явно задаёт:

```toml
[general]
use_middle_proxy = false
me2dc_fallback = true
me2dc_fast = true

[general.modes]
classic = false
secure = true
tls = false
```

Новые соединения по умолчанию используют прямой Direct-DC маршрут. Режим Telegram
Middle-End можно включить флагом `--middle-proxy`, если он лучше работает у
конкретного провайдера. Это предотвращает
состояние, при котором TCP-соединение с VPS есть, а рабочей дороги до Telegram
нет.

## Проверка готовности

Контейнер предоставляет локальный Control API на `127.0.0.1:9091`. Он не
публикуется на хост и недоступен из интернета.

Установщик выполняет две проверки:

```text
healthcheck liveness -> процесс и Control API работают
healthcheck ready    -> upstream-маршрут готов принимать клиентский трафик
```

После этого `mtgctl doctor` проверяет listener и TCP-доступность Telegram DC.
При ошибке установка по умолчанию завершается ненулевым кодом и не сообщает
ложный успех.

## Systemd и Docker

Образ загружается во время установки или команды `mtgctl update`. Обычный
рестарт сервиса не выполняет `docker pull`, поэтому временная недоступность
registry не мешает перезапустить уже установленный прокси.

Контейнер запускается со следующими ограничениями:

- read-only root filesystem;
- непривилегированный пользователь контейнера `65532:65532`;
- сброшены все Linux capabilities;
- `no-new-privileges`;
- ограниченная tmpfs;
- `nofile` до 262144;
- Docker log rotation `10m x 5`.

## Секреты

Каждая строка `users.tsv` содержит label, 32-hex secret и дату создания. Все
ключи одновременно записываются в `[access.users]`.

Клиентская ссылка всегда формируется как:

```text
tg://proxy?server=HOST&port=PORT&secret=dd<32-hex-secret>
```

Префикс `dd` включается только на стороне клиента. В конфигурации Telemt хранится
исходный 32-hex secret без префикса.

## Миграция

Перед установкой скрипт отключает `mtg.service` и удаляет контейнер `mtg-proxy`,
чтобы освободить порт. Старый `/etc/mtg` не удаляется. Новая конфигурация живёт
в отдельном каталоге, поэтому её можно удалить без повреждения резервной копии.
