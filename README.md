# ByeDPI Installer and Configurator (ALT Linux)

Автоматический установщик и конфигуратор **ByeDPI** для ALT Linux
(проверялось на Sisyphus, p10+ / p11).

---

## Описание сервиса

**ByeDPI** — локальный прокси-демон, который «разжимает» ответы по протоколам DPI
(Deep Packet Inspection) провайдера. Он не подменяет DNS и не маскирует трафик
полностью, а лишь корректирует способ отправки запросов так, чтобы блокирующая
сторона не могла по характерным признакам отличить реальный трафик и зарезать его.

Как это применяется на практике:

- YouTube / rutracker / instagram и прочие заблокированные домены продолжают
  работать без VPN.
- Весь остальной трафик идёт мимо ByeDPI и не затрагивается.

### Что делает скрипт

1. Обновляет список пакетов (`apt-get update`).
2. Устанавливает пакет `byedpi` через `apt-get`; если пакета нет — скачивает
   готовый бинарник `ciadpi` с GitHub (hufrea/byedpi releases).
3. Пишет конфигурацию отдельными файлами: `/etc/byedpi/port`, `/etc/byedpi/rule`,
   `/etc/byedpi/hosts` и управляющий `/etc/byedpi/conf` с переменными-указателями
   на эти файлы (для user-режима — в `~/.config/byedpi/`).
4. При первой установке **сам подбирает стратегию**: прогоняет список доменов
   через несколько кандидатов правил desync и записывает лучшее в `rule`
   (пересборка — командой `--test`).
5. Создаёт systemd-сервисы: сам демон (через launcher `byedpi-start`, собирающий
   опции ciadpi из отдельных файлов при каждом старте), а для ipset-режима ещё
   и правила перенаправления REDIRECT.
6. Включает автозапуск и выводит статус.

Демон слушает на `127.0.0.1:<порт>` (по умолчанию `14228`).

> **Права root:** в ALT обычно нет `sudo`, поэтому скрипт повышает права через
> `su -s /bin/sh -c '...' root` (будет запрошен пароль root). Если `sudo`
> установлен — используется он.

---

## Установка

### Автоматическая установка

Скрипт не интерактивный: значения задаются флагами (по умолчанию
`--system --extension`):

1. **Куда установить** — `--system` (все пользователи) или `--user` (только для текущего пользователя)
2. **Как использовать** — `--ipset` (весь TCP 80/443 через ByeDPI, фильтр по SNI) или `--extension` (SOCKS-прокси для расширения браузера)

Интерактивно:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh
```

С флагами (не требуют ввода):

```bash
# для всех пользователей, без расширений (только домены из hostlist)
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --system --ipset

# для всех пользователей, SOCKS-прокси для расширения браузера
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --system --extension

# только для текущего пользователя, без расширений
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --user --ipset

# только для текущего пользователя, SOCKS-прокси для расширения браузера
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --user --extension
```

> Скрипт собирается устанавливать пакет `byedpi` через `apt-get` из репозиторов
> ALT Linux (Sisyphus). Если пакета нет в вашей ветке — автоматически
> скачивается бинарник `ciadpi` с GitHub; права для установки поднимаются через
> `su -s /bin/sh -c '...' root` (без sudo).

---

## Удаление и управление

### Статус

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --status
```

### Полное отключение (удаление правил и сервисов)

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --off
```

Останавливает и удаляет сервисы, правила iptables/ipset (и system-, и
user-режимов), таймеры и конфиг-каталоги `/etc/byedpi` / `~/.config/byedpi`,
а также чистит следы старых версий (`/etc/sysconfig/byedpi` и пр.).

### Сервис вручную

```bash
# система (для всех пользователей)
sudo systemctl start byedpi          # запуск
sudo systemctl restart byedpi        # перезапуск после смены настроек
sudo systemctl status byedpi         # статус
sudo systemctl stop byedpi           # остановка
```

В user-режиме — то же через systemd-user сервис (без sudo, запускается при входе):

```bash
systemctl --user restart byedpi
```

---

## Режимы установки

### system (для всех пользователей)

- конфиг-каталог: `/etc/byedpi/` — `conf`, `rule`, `port`, `hosts`
- демон: systemd-сервис `byedpi.service` (`ExecStart=/usr/local/bin/byedpi-start`)
- порт: `14228`

### user (только для текущего пользователя)

- конфиг-каталог: `~/.config/byedpi/` — `conf`, `rule`, `port`, `hosts`
- демон: для ipset — root-юнит `byedpi-<uid>.service` + REDIRECT
  `byedpi-redirect-<uid>.service` (трафик только этого пользователя через
  `--uid-owner`, hostlist/конфиг остаются в `~/.config`); для extension —
  systemd-**user**-сервис `byedpi.service` (запускается при входе)
- порт для каждого пользователя свой: `14228 + (uid - 1000)`, чтобы юзеры не конфликтовали

Каждый пользователь может запустить скрипт повторно со своими `--user` флагами,
не затрагивая остальных.

---

## Как использовать: ipset или extension

| | `--ipset` | `--extension` |
|---|---|---|
| Расширения браузера | не нужны | нужны (FoxyProxy / SmartProxy / SwitchyOmega 3) |
| Охват | только домены из hostlist | только то, что настроено в расширении |
| Root | нужен (правила в ядре) | не нужен |
| UDP/QUIC | не обрабатывается | не обрабатывается |

### ipset — работа без расширений

Правило `iptables -t nat` `REDIRECT` (порты 80/443, TCP) заворачивает **весь**
исходящий трафик в локальный порт ByeDPI. Дальше ByeDPI смотрит на SNI (домен)
в TLS-запросе и десинхронизирует только те соединения, чей домен есть в
hostlist — как это делает расширение в SOCKS-режиме. Это надёжно работает и для
CDN-доменов (googlevideo), у которых тысячи IP: фильтр идёт по домену, а не по
IP, поэтому ipset и таймер обновления не нужны. Остальной трафик идёт напрямую.

```bash
nano /etc/byedpi/hosts        # или ~/.config/byedpi/hosts для user
/etc/init.d/byedpi restart    # или: systemctl restart byedpi
```

### extension — SOCKS-прокси

ByeDPI поднимает SOCKS на `127.0.0.1:<порт>`. Настройте прокси-расширение на
этот адрес и импортируйте список доменов. Готовый бэкап настроек SwitchyOmega
лежит в репозитории.

---

## Как изменить настройки

Порт, правило desync и список доменов лежат в **отдельных файлах** — менять их
можно по одному, не трогая остальные:

| Что настраиваем | system | user |
|---|---|---|
| список доменов | `/etc/byedpi/hosts` | `~/.config/byedpi/hosts` |
| стратегия desync | `/etc/byedpi/rule` | `~/.config/byedpi/rule` |
| порт | `/etc/byedpi/port` | `~/.config/byedpi/port` |
| управляющий конфиг | `/etc/byedpi/conf` | `~/.config/byedpi/conf` |

`conf` — управляющий файл с **переменными-указателями** на `rule`/`port`/`hosts`.
Демон запускается через launcher `byedpi-start`, который при каждом старте
читает эти файлы и собирает опции ciadpi — правки вступают в силу перезапуском
сервиса без переустановки.

```bash
nano /etc/byedpi/hosts                  # изменить список доменов
/etc/init.d/byedpi restart              # без systemd
systemctl restart byedpi                # systemd / system-режим
```

### Смена стратегии desync (автоподбор)

Правило лежит в файле `rule` одной строкой. Готовые варианты — в файле
`Стратегии byedpi.txt` репозитория:

```bash
nano /etc/byedpi/rule
systemctl restart byedpi                # или /etc/init.d/byedpi restart
```

**Автоподбор:** при первой установке (и по команде `--test`) скрипт прогоняет
список доменов через нескольких кандидатов правил и записывает в `rule` то,
которое открывает больше всего ресурсов из списка:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && sh /tmp/byedpi-alt.sh --test
```

Пропустить автоподбор при установке можно флагом `--no-test`.

---

## Рекомендации по настройке браузера

Для extension-режима используются расширения-переключатели прокси:

- FoxyProxy
- SmartProxy
- Proxy SwitchyOmega 3

Готовый бэкап настроек SwitchyOmega лежит в репозитории. Набор доменов покрывает
страницы, плеер и превью YouTube: `*.youtube.com`, `*.googlevideo.com` (видео),
`*.ytimg.com` / `i.ytimg.com` (превью и картинки), `yt3.ggpht.com` /
`*.ggpht.com` / `yt3.googleusercontent.com` (аватары), а также rutracker,
instagram, discord и др.

---

## Ограничения transparent-режима

Transparent-режим (ipset) перенаправляет только TCP. UDP (например, QUIC от
YouTube) не обрабатывается — при необходимости отключите QUIC в браузере
(`chrome://flags/#enable-quic` → Disabled), чтобы видео шло по TCP 443.

---

## Безопасность

- Запрещает запуск от root (чтобы избежать непредвиденных проблем).
- Повышает права автоматически: от root напрямую, иначе через `sudo`, иначе
  через `su -s /bin/sh -c '...' root` (ALT без sudo).
- В ipset-режиме отсекает служебные подсети (локальные адреса) от
  перенаправления, чтобы не заворачивать собственный трафик.

---

## Поддерживаемые дистрибутивы и версии

Ориентировочно, проверялось на ALT Sisyphus (byedpi 0.17.x из репозитория):

- ALT Linux Sisyphus
- ALT Linux p10 / p11 (если пакет `byedpi` присутствует в репозитории ветки)
- Вариации ALT на Sisyphus (Simply Linux и др., по факту наличия пакета)

> Пакет `byedpi` в ALT собирается с бинарём `ciadpi` (тот же daemon, что и
> `ciadpi` в Arch-пакете `byedpi-bin`). Если в вашей ветке ALT пакета нет —
> обновите репозитории или используйте ветку, где он есть.
