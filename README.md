# ByeDPI Installer and Configurator (ALT Linux)

Автоматический установщик и конфигуратор **ByeDPI** для ALT Linux
(проверялось на Sisyphus, p10+ / p11).

## Быстрый старт

Основная установка — **без расширения** (`ipset`: весь TCP 80/443 идёт через
ByeDPI, фильтр по SNI, в браузере ничего настраивать не нужно):

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh
```

Режим с расширением (SOCKS-прокси для браузера):

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --extension
```

Статус, перепроверка и удаление:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --status
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --check
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --off
```

`--off` удаляет сервисы, правила iptables, конфиги **и сам byedpi** (пакет
`byedpi-bin` / `byedpi` или скачанный `ciadpi`). Оставить пакет:
`--off --keep-package`.

> Запускать можно и через `sh /tmp/byedpi-alt.sh` — `chmod +x` нужен только для
> прямого запуска вида `/tmp/byedpi-alt.sh --status`.

---

## Описание сервиса

**ByeDPI** — локальный прокси-демон, который «разжимает» ответы по протоколам
DPI (Deep Packet Inspection) провайдера. Он не подменяет DNS и не маскирует
трафик полностью, а лишь корректирует способ отправки запросов так, чтобы
блокирующая сторона не могла по характерным признакам отличить реальный трафик
и зарезать его.

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

## Содержимое репозитория

| Файл | Назначение |
|---|---|
| `autoinstall_byedpi_altlinux.sh` | Сам установщик. Скачивается и запускается одной командой (см. ниже) |
| `Стратегии byedpi.txt` | Готовые стратегии desync. Можно копировать из него строки в файл `/etc/byedpi/rule` (или `~/.config/byedpi/rule`) вручную |
| `ZeroOmegaOptions-2025-08-07T17_33_48.644Z.bak` | Готовый бэкап настроек прокси-расширения SwitchyOmega (ZeroOmega): домены YouTube, rutracker, instagram, discord и др. Импортируется в расширение через «Восстановить из файла» |
| `LICENSE` | Лицензия GPL-3.0 |

---

## Установка

> По умолчанию (без флагов) ставится режим **ipset** — без расширения:
> весь TCP 80/443 идёт через ByeDPI с фильтром по SNI, браузер настраивать
> не нужно. Режим с расширением включается флагом `--extension`.

### Требования

- ALT Linux (Sisyphus, p10/p11) с доступом в интернет.
- Пользователь с правами на повышение: `sudo` или пароль root для `su`.
- Для автотеста стратегий нужен `curl` (обычно уже установлен).

### Автоматическая установка (интерактивно)

Скрипт задаст два вопроса: **куда установить** (система или только для текущего
пользователя) и **как использовать** (ipset или расширение):

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh
```

### Установка с флагами (без вопросов)

Если ответы известны заранее, их можно задать флагами — ввод не потребуется.

**Вариант 1. Для всех пользователей, без расширений (только домены из hostlist):**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --system --ipset
```

**Вариант 2. Для всех пользователей, SOCKS-прокси для расширения браузера:**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --system --extension
```

**Вариант 3. Только для текущего пользователя, без расширений:**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --user --ipset
```

**Вариант 4. Только для текущего пользователя, SOCKS-прокси для расширения браузера:**

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --user --extension
```

> **Какой вариант выбрать?**
> - `--ipset` — всё работает само, расширения в браузере не нужны (но нужен
>   root и правится файл `hosts`).
> - `--extension` — нужна настройка расширения в браузере, зато root не нужен.
>
> Подробнее — в разделе «Как использовать: ipset или extension».

> Скрипт пытается поставить пакет `byedpi` через `apt-get` из репозиториев ALT
> Linux (Sisyphus). Если пакета нет в вашей ветке — автоматически скачивается
> бинарник `ciadpi` с GitHub; права для установки поднимаются через
> `su -s /bin/sh -c '...' root` (без sudo).

---

## Управление

### Статус

Показать, что установлено и работает ли демон:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --status
```

### Полное отключение (удаление правил и сервисов)

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --off
```

Команда `--off` останавливает и удаляет сервисы, правила iptables/ipset (и
system-, и user-режимов), таймеры, конфиг-каталоги `/etc/byedpi` /
`~/.config/byedpi`, пакет `byedpi` (или скачанный `ciadpi`) и следы старых
версий (`/etc/sysconfig/byedpi` и пр.). Оставить пакет — `--off --keep-package`.

> После `--off` установить ByeDPI заново можно обычной командой установки.

### Сервис вручную

Запуск:

```bash
sudo systemctl start byedpi
```

Перезапуск после смены настроек:

```bash
sudo systemctl restart byedpi
```

Статус:

```bash
sudo systemctl status byedpi
```

Остановка:

```bash
sudo systemctl stop byedpi
```

В user-режиме — те же команды, но для systemd-user сервиса (без sudo,
запускается при входе):

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
| UDP/QUIC | блокируется по умолчанию (`byedpi-quic`), браузер идёт по TCP | не обрабатывается |

> **Нельзя одновременно.** В ipset-режиме порт `<порт>` — не SOCKS-прокси, а
> точка перехвата для iptables. Если браузер настроен на `socks5 127.0.0.1:<порт>`
> (например, ZeroOmega/FoxyProxy с профилем из `.bak`), каждое соединение будет
> мгновенно рваться: SOCKS-запрос уходит в перехватчик, который его не понимает.
> Перед ipset-установкой переключите расширение в «прямое соединение» или
> выключите его. Проверить, что режим и перехват согласованы: `--check` и
> `--status` (печатают режим и предупреждают о таком конфликте).
>
> **QUIC (UDP 443) не перехватывается, поэтому блокируется.** ByeDPI заворачивает
> только TCP, а браузер сначала пробует HTTP/3. Если провайдер режет UDP 443,
> браузер ждёт таймаут — это и есть чёрный экран и крутилка YouTube при рабочем
> TCP. Поэтому в transparent-режиме по умолчанию ставится юнит `byedpi-quic`:
> UDP 443 получает быстрый `REJECT`, и браузер сразу переключается на TCP.
> Отключить: `--allow-quic`. Включить обратно: `--block-quic`.


### ipset — работа без расширений

Правило `iptables -t nat` `REDIRECT` (порты 80/443, TCP) заворачивает **весь**
исходящий трафик в локальный порт ByeDPI. Дальше ByeDPI смотрит на SNI (домен)
в TLS-запросе и десинхронизирует только те соединения, чей домен есть в
hostlist — как это делает расширение в SOCKS-режиме. Это надёжно работает и для
CDN-доменов (googlevideo), у которых тысячи IP: фильтр идёт по домену, а не по
IP, поэтому ipset и таймер обновления не нужны. Остальной трафик идёт напрямую.

Отредактировать список доменов:

```bash
sudo nano /etc/byedpi/hosts
```

Для user-режима:

```bash
nano ~/.config/byedpi/hosts
```

Перезапустить демон:

```bash
sudo systemctl restart byedpi
```

Если systemd не используется:

```bash
/etc/init.d/byedpi restart
```

### extension — SOCKS-прокси

ByeDPI поднимает SOCKS на `127.0.0.1:<порт>`. Настройте прокси-расширение на
этот адрес и импортируйте список доменов. Готовый бэкап настроек SwitchyOmega
(`ZeroOmegaOptions-*.bak`) лежит в репозитории — импортируется через «Восстановить
из файла» в настройках расширения.

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

### Изменить список доменов (ipset-режим)

Редактируем файл:

```bash
sudo nano /etc/byedpi/hosts
```

Перезапускаем демон:

```bash
sudo systemctl restart byedpi
```

### Сменить порт

Вписать число, например `14229`:

```bash
sudo nano /etc/byedpi/port
```

Перезапустить демон:

```bash
sudo systemctl restart byedpi
```

В ipset-режиме перезапустите также правила перенаправления:

```bash
sudo systemctl restart byedpi-redirect
```

### Смена стратегии desync (автоподбор)

Правило лежит в файле `rule` одной строкой. Готовые варианты — в файле
`Стратегии byedpi.txt` репозитория.

Редактируем правило:

```bash
sudo nano /etc/byedpi/rule
```

Перезапускаем демон:

```bash
sudo systemctl restart byedpi
```

**Автоподбор:** при первой установке (и по команде `--test`) скрипт прогоняет
минимальный набор доменов (rutracker, nnm-club, YouTube, Discord)
через нескольких кандидатов правил и записывает в `rule` то, которое открывает
больше всего из них:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh -o /tmp/byedpi-alt.sh && chmod +x /tmp/byedpi-alt.sh && /tmp/byedpi-alt.sh --test
```

Пропустить автоподбор при установке можно флагом `--no-test`.

Проверить, что открывается прямо сейчас:

```bash
/tmp/byedpi-alt.sh --check
```

| вердикт | что означает | что делать |
|---|---|---|
| `OK (код)` | ресурс открывается | ничего |
| `OK с N-й попытки` | DPI фильтрует статистически | перезагрузить страницу |
| `FAIL (домен есть в hosts, правило не помогает)` | домен в списке desync, но не открывается | сменить правило (`--test`) |
| `FAIL (напрямую открывается, но домена нет в hosts)` | домен забыт в списке | дописать в `hosts`, перезапустить демон |
| `FAIL 3/3 — блок по IP или по отпечатку` | не открывается ни напрямую, ни с повторами | desync/SNI **не поможет** |

Фильтрация ТСПУ бывает **статистической**: соединение иногда не устанавливается
с первого раза при любом правиле desync. Блокировки по IP при этом нет —
SYN-ACK приходит быстро, RST прилетает уже на ClientHello; `--check` пишет
«OK с N-й попытки».

**Почему Telegram нет в списках доменов.** С 05.06.2026 Telegram режет по
JA3-отпечатку TLS ClientHello и по числу одновременных соединений (ntc.party,
«MTProto в 2026 году»; подтверждено разработчиками telemt). Отпечаток не
меняется от desync/fake/split, подмена SNI не помогает — проверено. Держать
`telegram.org`/`t.me` в hostlist бессмысленно. Рабочие варианты: прокси
(MTProto/FakeTLS), VPN или клиент с `tdlib-obf`.

---

## Рекомендации по настройке браузера

Для extension-режима используются расширения-переключатели прокси:

- FoxyProxy
- SmartProxy
- Proxy SwitchyOmega 3

Готовый бэкап настроек SwitchyOmega лежит в репозитории (63 правила, список
синхронизирован с hosts-файлом byedpi). YouTube покрыт целиком: `*.youtube.com`,
`*.googlevideo.com` (видео), `*.ytimg.com`, `yt3.ggpht.com`, `*.ggpht.com`,
`yt3.googleusercontent.com`, `*.img.youtube.com`, `*.m.youtube.com`, `*.gstatic.com`,
`*.googleusercontent.com`, `*.l.google.com`, `*.1e100.net`, `*.youtube.ru` —
это то, что грузит плеер, превью и аватары. Плюс rutor, rutracker, nnm-club,
discord и соцсети.

Мёртвые домены вычищены: `archlinuxgui.in` (SERVFAIL) и `flibusta.lib` (NXDOMAIN)
удалены, дубликат `*.habr.com` убран. Telegram в списке нет намеренно — он режется
по JA3-отпечатку, прокси-расширение его тоже не спасёт (нужен MTProxy/FakeTLS или VPN).

---

## Ограничения transparent-режима

Transparent-режим (ipset) перенаправляет только TCP. UDP/QUIC не перехватить
через REDIRECT, поэтому скрипт решает задачу иначе — быстрым отказом:

```bash
iptables -t filter -A BYEDPI_QUIC -p udp --dport 443 \
    -m owner ! --uid-owner 0 -j REJECT --reject-with icmp-port-unreachable
```

Это делает отдельный юнит `byedpi-quic.service` (`byedpi-quic-<uid>` в
user-scope; включён по умолчанию). Браузер получает `ICMP port unreachable`
и сразу идёт по TCP 443, не дожидаясь таймаута HTTP/3. Замер на реальном
видео-потоке googlevideo: HTTP/2 через ByeDPI — 10/10, HTTP/3 напрямую — 0/10.

Если блокировка не нужна (например, QUIC у провайдера работает): `--allow-quic`.
Проверить состояние: `--status` и `--check` (последний реально пробует HTTP/3).


### Обновление конфигов при повторном запуске

`hosts` и `rule` **всегда перезаписываются** содержимым скрипта — скрипт ставится
с сервера, значит списки доменов и правила desync всегда актуальные. Предыдущая
версия не теряется: рядом появляется `hosts.bak-<дата>` и `rule.bak-<дата>`.

```bash
$0 --update          # обновить hostlist, правило, launcher и юнит, перезапустить
$0 --update --keep-files   # обновить только launcher/юнит, файлы не трогать
$0 --check           # проверить, что после обновления открывается
```

`port` и режим работы (`conf`) при обновлении не меняются — это ваш выбор.


---

## Безопасность

- Запрещает запуск от root (чтобы избежать непредвиденных проблем).
- Повышает права автоматически: от root напрямую, иначе через `sudo`, иначе
  через `su -s /bin/sh -c '...' root` (ALT без sudo).
- В ipset-режиме отсекает служебные подсети (локальные адреса) от
  перенаправления, чтобы не заворачивать собственный трафик.

---

## Полный список флагов

```
Использование: autoinstall_byedpi_altlinux.sh [--system|--user]
                 [--ipset|--extension] [--off|--status|--test|--check|--update]
                 [--port N] [--no-test] [--keep-files] [--block-quic|--allow-quic]
  --system        установить для всех пользователей (конфиг /etc/byedpi/)
  --user          установить только для текущего пользователя
  --ipset         метод ipset: весь TCP 80/443 через ByeDPI, фильтр по SNI
  --extension     метод extension: SOCKS-прокси для браузерного расширения
  --block-quic    блокировать UDP 443 (QUIC): браузер сразу идёт по TCP
                  (по умолчанию включено для transparent)
  --allow-quic    не блокировать QUIC
  --test          перезапустить автотест стратегий и обновить rule
  --check         проверить минимальный набор доменов (youtube/discord/rutracker/
                  nnm-club) и сказать, что именно не открывается
  --no-test       пропустить автотест стратегий при установке
  --keep-files    не трогать существующие hosts/rule (по умолчанию они
                  перезаписываются версией из скрипта, старое -> .bak-<дата>)
  --update        обновить hosts/rule/launcher/юниты из скрипта и перезапустить
  --off | --remove  отключить, удалить сервисы, правила и конфиги
  --status|--info   показать текущее состояние
  --port N        изменить порт
  --socks         = --system --extension (старая совместимость)
  --transparent   = --system --ipset (старая совместимость)
  --transparent-off = --off
```

---

## Поддерживаемые дистрибутивы и версии

Ориентировочно, проверялось на ALT Sisyphus (byedpi 0.17.x из репозитория):

- ALT Linux Sisyphus
- ALT Linux p10 / p11 (если пакет `byedpi` присутствует в репозитории ветки)
- Вариации ALT на Sisyphus (Simply Linux и др., по факту наличия пакета)

> Пакет `byedpi` в ALT собирается с бинарём `ciadpi` (тот же daemon, что и
> `ciadpi` в Arch-пакете `byedpi-bin`). Если в вашей ветке ALT пакета нет —
> обновите репозитории или используйте ветку, где он есть.