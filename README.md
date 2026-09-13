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
2. Устанавливает пакет `byedpi` (и `ipset`, если выбран ipset-режим).
3. Пишет конфигурацию ByeDPI с предустановленными параметрами (путь зависит от
   выбранного режима, см. ниже).
4. Создаёт systemd-сервисы: сам демон, а для ipset-режима ещё и правила
   перенаправления + таймер обновления списка доменов.
5. Включает автозапуск и выводит статус.

Демон слушает на `127.0.0.1:<порт>` (по умолчанию `14228`).

---

## Установка

### Автоматическая установка

Скрипт спрашивает два вопроса (или можно задать их флагами):

1. **Куда установить** — `--system` (все пользователи) или `--user` (только для текущего пользователя)
2. **Как использовать** — `--ipset` (без расширений, только домены из списка) или `--extension` (SOCKS-прокси для расширения браузера)

Интерактивно:

```bash
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh)
```

С флагами (не требуют ввода):

```bash
# для всех пользователей, без расширений (только домены из hostlist)
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --system --ipset

# для всех пользователей, SOCKS-прокси для расширения браузера
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --system --extension

# только для текущего пользователя, без расширений
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --user --ipset

# только для текущего пользователя, SOCKS-прокси для расширения браузера
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --user --extension
```

> Скрипт собирается устанавливать пакет `byedpi` через `apt-get` из репозиторов
> ALT Linux (Sisyphus). Если пакет не найден — повторяет `apt-get update` и
> пробует ещё раз.

---

## Удаление и управление

### Статус

```bash
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --status
```

### Полное отключение (удаление правил и сервисов)

```bash
sh <(curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_byedpi_altlinux/main/autoinstall_byedpi_altlinux.sh) --off
```

Останавливает и удаляет сервисы, таймеры, правила iptables/ipset (и system-, и
user-режимов). Конфиги при этом не удаляются — остаются по путям ниже.

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

- конфиг: `/etc/sysconfig/byedpi`
- hostlist: `/etc/byedpi-hosts.txt` (для ipset-режима)
- демон: systemd-сервис `byedpi.service`
- порт: `14228`

### user (только для текущего пользователя)

- конфиг: `~/.config/byedpi.conf`
- hostlist: `~/.config/byedpi-hosts.txt` (для ipset-режима)
- демон: systemd-**user**-сервис `byedpi.service` (запускается при входе)
- порт для каждого пользователя свой: `14228 + (uid - 1000)`, чтобы юзеры не конфликтовали
- для ipset-режима сгенерированный ipset и правила REDIRECT привязаны к `--uid-owner`
  этого пользователя и затрагивают только его трафик (сам ipset живёт в ядре,
  поэтому корневые unit-ы `byedpi-hosts-<uid>` / `byedpi-redirect-<uid>` всё же
  создаются в `/etc/systemd/system`, но читают hostlist из `~/.config`)

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

Домены из hostlist резолвятся в IP и складываются в ipset. Правило `iptables -t nat`
`REDIRECT` матчит ТОЛЬКО пакеты, чей адрес назначения есть в этом ipset
(порты 80/443, TCP), и заворачивает их в локальный порт ByeDPI. Остальной трафик
идёт напрямую. ipset обновляется таймером каждый час.

```bash
sudo nano /etc/byedpi-hosts.txt        # или ~/.config/byedpi-hosts.txt для user
sudo systemctl restart byedpi-hosts byedpi-redirect
```

### extension — SOCKS-прокси

ByeDPI поднимает SOCKS на `127.0.0.1:<порт>`. Настройте прокси-расширение на
этот адрес и импортируйте список доменов. Готовый бэкап настроек SwitchyOmega
лежит в репозитории.

---

## Как изменить список доменов

### ipset-режим (без расширений)

Отредактируйте hostlist и перезапустите сервисы:

```bash
sudo nano /etc/byedpi-hosts.txt                                # system
sudo systemctl restart byedpi-hosts byedpi-redirect

nano ~/.config/byedpi-hosts.txt                                # user
systemctl --user restart byedpi-hosts byedpi-redirect          # user
```

Изменения ipset пересоберутся автоматически либо по таймеру (раз в час), либо
при перезапуске сервисов.

### extension-режим

Список доменов хранится в расширении браузера. Правьте его через интерфейс
расширения или восстановите готовый бэкап из репозитория. Изменения конфига:

```bash
sudo nano /etc/sysconfig/byedpi            # system
sudo systemctl restart byedpi

nano ~/.config/byedpi.conf                 # user
systemctl --user restart byedpi            # user
```

### Смена стратегии desync

Параметры стратегии лежат в файле `BYEDPI_OPTIONS` внутри конфига. Готовые
стратегии можно взять из файла `Стратегии byedpi.txt` в репозитории — подставьте
нужную строку в конфиг и перезапустите сервис.

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
- Проверяет, есть ли у текущего пользователя права sudo.
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
