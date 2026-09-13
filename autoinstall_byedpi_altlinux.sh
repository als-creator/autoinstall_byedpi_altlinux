#!/bin/bash
#
# ByeDPI installer (ALT Linux / Sisyphus)
#
# Режимы (по аналогии с autoinstall_byedpi_archlinux):
#
#   Область установки:
#     --system — для всех пользователей (конфиг /etc/sysconfig/byedpi)
#     --user   — только для текущего пользователя (конфиг ~/.config/byedpi.conf,
#                systemd-user сервис, порт свой на каждого пользователя)
#
#   Метод работы:
#     --ipset  — без браузерных расширений. hostlist резолвится в ipset, правила
#                REDIRECT матчат только IP из списка. ipset живёт в ядре —
#                заполнение требует root. В user-режиме правило привязано к
#                --uid-owner, поэтому затрагивает трафик ТОЛЬКО этого пользователя.
#     --extension — SOCKS-прокси 127.0.0.1:порт, конфигурируется в расширении
#                браузера (FoxyProxy / SmartProxy / SwitchyOmega 3). Root не нужен.
#
# Отключение:
#     --off  — останавливает и удаляет сервисы/таймеры/правила/ipset
#     --status — показывает текущий статус и пути
#
set -e

die(){ echo "[ERROR] $*" >&2; exit 1; }
log(){ echo "[OK] $*"; }
warn(){ echo "[WARN] $*"; }

# ---------------------------------------------------------------------------
# Парсинг аргументов
# ---------------------------------------------------------------------------
SCOPE=""          # system | user
METHOD=""         # ipset | extension
ACTION="install"  # install | off | status
ARG_PORT=""

for a in "$@"; do
  case "$a" in
    --system)    SCOPE=system ;;
    --user)      SCOPE=user ;;
    --ipset)     METHOD=ipset ;;
    --extension) METHOD=extension ;;
    --off|--remove) ACTION=off ;;
    --status|--info) ACTION=status ;;
    --help|-h)
      echo "Использование: $0 [--system|--user] [--ipset|--extension] [--off|--status] [--port N]"
      exit 0 ;;
    --port=*)    ARG_PORT="${a#*=}" ;;
    --socks)     SCOPE=system; METHOD=extension ;;  # совместимость со старым
    --transparent) SCOPE=system; METHOD=ipset ;;    # совместимость со старым
    --transparent-off) ACTION=off ;;
    *) die "Неизвестный аргумент: $a (см. $0 --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Проверка окружения
# ---------------------------------------------------------------------------
[ "$EUID" -eq 0 ] && die "Не запускайте скрипт от root."
command -v sudo >/dev/null 2>&1 || die "sudo не установлен"

if [ "$ACTION" = "install" ]; then
  if [ -z "$SCOPE" ] && [ -t 0 ]; then
    echo "=== Куда установить? ==="
    echo "  1) Система (все пользователи)"
    echo "  2) Только для текущего пользователя"
    printf "Выбор (1/2): "; read -r c
    [ "$c" = "2" ] && SCOPE=user || SCOPE=system
  fi
  [ -z "$SCOPE" ] && SCOPE=system
  if [ -z "$METHOD" ] && [ -t 0 ]; then
    echo "=== Как использовать? ==="
    echo "  1) ipset — без расширений, только домены из списка"
    echo "  2) extension — расширение в браузере (SOCKS)"
    printf "Выбор (1/2): "; read -r c
    [ "$c" = "1" ] && METHOD=ipset || METHOD=extension
  fi
  [ -z "$METHOD" ] && METHOD=extension
fi

UID_NUM=$(id -u)

# ---------------------------------------------------------------------------
# Пакеты
# ---------------------------------------------------------------------------
echo "Обновление списка пакетов..."
sudo apt-get update -y >/dev/null 2>&1 || sudo apt-get update -y

if ! rpm -q byedpi >/dev/null 2>&1 && ! dpkg -l byedpi >/dev/null 2>&1; then
  echo "Попытка установки byedpi..."
  sudo apt-get install -y byedpi >/dev/null 2>&1 || {
    warn "apt-get install byedpi не удался, пробуем ещё раз..."
    sudo apt-get update -y && sudo apt-get install -y byedpi
  }
fi
if [ "$METHOD" = "ipset" ]; then
  sudo apt-get install -y ipset >/dev/null 2>&1 || warn "ipset не установлен — проверьте репозитории"
fi

# ---------------------------------------------------------------------------
# Значения по режиму
# ---------------------------------------------------------------------------
UP=/usr/local/bin/byedpi-hosts-update.sh
if [ "$SCOPE" = "user" ]; then
  CFG="$HOME/.config/byedpi.conf"
  HOSTS="$HOME/.config/byedpi-hosts.txt"
  DAEMON_CTL=(systemctl --user)
  IHOSTS="BYEDPI_$UID_NUM"
  UP="/usr/local/bin/byedpi-hosts-update-$UID_NUM.sh"
  PORT=$(( 14228 + UID_NUM - 1000 ))
  [ -n "$ARG_PORT" ] && PORT="$ARG_PORT"
else
  CFG="/etc/sysconfig/byedpi"
  HOSTS="/etc/byedpi-hosts.txt"
  DAEMON_CTL=(sudo systemctl)
  IHOSTS="BYEDPI_HOSTS"
  PORT="${ARG_PORT:-14228}"
fi

HOSTLIST_OPTIONS="-i 127.0.0.1 --port $PORT"
if [ "$METHOD" = "ipset" ]; then
  HOSTLIST_OPTIONS+=" -E"
fi
HOSTLIST_OPTIONS+=" -Kt,h -s0 -o1 -Ar -o1 -At -f-1 --md5sig -r1+s -As,n -Ku -a5 -An"

# ---------------------------------------------------------------------------
# off / status
# ---------------------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
  echo "=== ByeDPI: статус ==="
  ${DAEMON_CTL[@]} --no-pager status byedpi 2>/dev/null | head -8 || true
  [ -f "$HOME/.config/byedpi.conf" ]    && echo "user config:   $HOME/.config/byedpi.conf"
  [ -f "$HOME/.config/byedpi-hosts.txt" ] && echo "user hostlist: $HOME/.config/byedpi-hosts.txt"
  [ -f /etc/sysconfig/byedpi ]  && echo "system config:  /etc/sysconfig/byedpi"
  exit 0
fi

if [ "$ACTION" = "off" ]; then
  echo "=== Отключение ByeDPI ==="
  systemctl --user disable --now byedpi.service 2>/dev/null || true
  systemctl --user disable --now byedpi-hosts.timer 2>/dev/null || true
  systemctl --user stop byedpi-hosts.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/byedpi.service"
  rm -f "$HOME/.config/systemd/user/byedpi-hosts.service"
  rm -f "$HOME/.config/systemd/user/byedpi-hosts.timer"
  systemctl --user daemon-reload 2>/dev/null || true

  for n in "byedpi-redirect" "byedpi-redirect-$UID_NUM" "byedpi-hosts.timer" "byedpi-hosts-$UID_NUM.timer"; do
    sudo systemctl disable --now "$n" 2>/dev/null || true
  done
  sudo systemctl stop byedpi-hosts.service 2>/dev/null || true
  sudo systemctl stop "byedpi-hosts-$UID_NUM.service" 2>/dev/null || true
  sudo systemctl disable --now byedpi 2>/dev/null || true

  # правила
  sudo iptables -t nat -D OUTPUT -j BYEDPI 2>/dev/null || true
  sudo iptables -t nat -D OUTPUT -j BYEDPI_$UID_NUM 2>/dev/null || true
  sudo iptables -t nat -F BYEDPI 2>/dev/null || true
  sudo iptables -t nat -F BYEDPI_$UID_NUM 2>/dev/null || true
  sudo iptables -t nat -X BYEDPI 2>/dev/null || true
  sudo iptables -t nat -X BYEDPI_$UID_NUM 2>/dev/null || true
  sudo ipset destroy BYEDPI_HOSTS 2>/dev/null || true
  sudo ipset destroy BYEDPI_$UID_NUM 2>/dev/null || true
  sudo rm -f /etc/systemd/system/byedpi-redirect.service \
             /etc/systemd/system/byedpi-redirect-$UID_NUM.service \
             /etc/systemd/system/byedpi-hosts.timer \
             /etc/systemd/system/byedpi-hosts-$UID_NUM.timer \
             /etc/systemd/system/byedpi-hosts.service \
             /etc/systemd/system/byedpi-hosts-$UID_NUM.service
  sudo systemctl daemon-reload 2>/dev/null || true
  echo "ByeDPI отключён. Конфиги не удалялись: $HOME/.config/byedpi.conf, /etc/sysconfig/byedpi"
  exit 0
fi

# ---------------------------------------------------------------------------
# Конфиг + hostlist
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config"
if [ "$SCOPE" = "user" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  echo "BYEDPI_OPTIONS=\"$HOSTLIST_OPTIONS\"" > "$CFG"
else
  echo "BYEDPI_ARGS=\"$HOSTLIST_OPTIONS\"" | sudo tee "$CFG" > /dev/null
fi
log "Конфиг: $CFG"

HOSTS_LIST=$'# ByeDPI hostlist — домены, к которым применяется desync.\n# Формат: один домен на строку, строки с # игнорируются.\n# Правка: отредактируйте и перезапустите сервисы (см. README).\nyoutube.com\nyoutube-nocookie.com\nyoutu.be\nytimg.com\nyt3.googleusercontent.com\ngooglevideo.com\ngoogleusercontent.com\nggpht.com\ngg.googleusercontent.com\ngvt1.com\nplay.google.com\naccounts.google.com\ngooglevideo.net\nfacebook.com\nfbcdn.net\ninstagram.com\ncdninstagram.com\ntwitter.com\ntwimg.com\nt.co\nx.com\nrutracker.org\nrutracker.cc\nrutor.info\nnnmclub.to\ndiscord.com\ndiscord.co\ndiscord.gg\ndiscordapp.com\ndiscordapp.net\ndiscordcdn.com\ndiscordstatus.com\ndiscord.media\ndis.gd\nhabr.com\nmedium.com\nproton.me\narchive.org\nsourceforge.net\n'
if [ ! -f "$HOSTS" ]; then
  if [ "$SCOPE" = "user" ]; then
    printf '%s' "$HOSTS_LIST" > "$HOSTS"
  else
    printf '%s' "$HOSTS_LIST" | sudo tee "$HOSTS" > /dev/null
  fi
  log "Создан hostlist: $HOSTS"
else
  warn "Hostlist уже есть, не перезаписан: $HOSTS"
fi

# ---------------------------------------------------------------------------
# Скрипт обновления hostlist -> ipset (root, читает system/user hostlist)
# ---------------------------------------------------------------------------
if [ "$METHOD" = "ipset" ]; then
  cat > /tmp/byedpi-up-sh.sh <<UP
#!/bin/bash
# Автосгенерировано установщиком ByeDPI. Заполняет ipset \$IHOSTS из \$HOSTS.
set -e
SET="\$IHOSTS"
LIST="\$HOSTS"
[ -f "\$LIST" ] || { echo "Нет hostlist: \$LIST" >&2; exit 0; }
ipset create "\$SET" hash:ip 2>/dev/null || true
ipset flush "\$SET"
while IFS= read -r domain; do
  [ -z "\$domain" ] && continue
  case "\$domain" in \#*) continue ;; esac
  getent ahosts "\$domain" 2>/dev/null | awk '{print \$1}' | sort -u | while read -r ip; do
    ipset add "\$SET" "\$ip" 2>/dev/null || true
  done
done < "\$LIST"
members=\$(ipset list "\$SET" 2>/dev/null | grep -cE '^[0-9a-fA-F:\.]+\$' || true)
echo "ByeDPI: IP в ipset \$SET: \$members"
exit 0
UP
  sudo install -m 755 /tmp/byedpi-up-sh.sh "$UP"
  rm -f /tmp/byedpi-up-sh.sh
  log "Скрипт обновления ipset: $UP"
fi

# ---------------------------------------------------------------------------
# systemd-юниты
# ---------------------------------------------------------------------------
UCFG="$HOME/.config"
if [ "$SCOPE" = "user" ]; then
  # ==== user scope ====
  cat > "$HOME/.config/systemd/user/byedpi.service" <<EOF
[Unit]
Description=ByeDPI (user $USER)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ciadpi \$BYEDPI_OPTIONS
EnvironmentFile=%h/.config/byedpi.conf
Restart=on-failure

[Install]
WantedBy=default.target
EOF

  if [ "$METHOD" = "ipset" ]; then
    # ipset требует root: корневые unit-ы, но привязаны к uid и читают hostlist юзера
    sudo tee "/etc/systemd/system/byedpi-hosts-$UID_NUM.service" >/dev/null <<EOF
[Unit]
Description=ByeDPI hostlist -> ipset (uid $UID_NUM)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UP

[Install]
WantedBy=multi-user.target
EOF
    sudo tee "/etc/systemd/system/byedpi-hosts-$UID_NUM.timer" >/dev/null <<EOF
[Unit]
Description=ByeDPI hostlist ipset refresh (uid $UID_NUM)
[Timer]
OnBootSec=1min
OnUnitActiveSec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    sudo tee "/etc/systemd/system/byedpi-redirect-$UID_NUM.service" >/dev/null <<EOF
[Unit]
Description=ByeDPI REDIRECT (uid $UID_NUM)
Wants=byedpi.service
After=byedpi.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
iptables -t nat -N $IHOSTS 2>/dev/null || true; \
iptables -t nat -F $IHOSTS; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 0.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 10.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 172.16.0.0/12 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 192.168.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 169.254.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -p tcp -m owner --uid-owner $UID_NUM -m set --match-set $IHOSTS dst -m multiport --dports 80,443 -j REDIRECT --to-ports $PORT; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c 'iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null || true; iptables -t nat -F $IHOSTS 2>/dev/null || true; iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "byedpi-hosts-$UID_NUM.timer" >/dev/null 2>&1 || warn "Не удалось включить таймер hostlist"
    sudo "$UP" || warn "Не удалось заполнить ipset сразу"
    sudo systemctl enable --now "byedpi-redirect-$UID_NUM.service" >/dev/null 2>&1 || warn "Не удалось включить REDIRECT"
  fi

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now byedpi.service >/dev/null 2>&1 || warn "user unit не запустился сразу (включится при входе)"
  log "Юзер-сервис: ~/.config/systemd/user/byedpi.service"
else
  # ==== system scope ====
  sudo systemctl enable --now byedpi >/dev/null 2>&1 || true
  if [ "$METHOD" = "ipset" ]; then
    sudo tee /etc/systemd/system/byedpi-hosts.service >/dev/null <<EOF
[Unit]
Description=ByeDPI hostlist -> ipset update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UP

[Install]
WantedBy=multi-user.target
EOF
    sudo tee /etc/systemd/system/byedpi-hosts.timer >/dev/null <<EOF
[Unit]
Description=ByeDPI hostlist ipset refresh

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    sudo tee /etc/systemd/system/byedpi-redirect.service >/dev/null <<EOF
[Unit]
Description=ByeDPI transparent redirect rules (hostlist)
Wants=byedpi.service byedpi-hosts.service
After=byedpi.service byedpi-hosts.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
iptables -t nat -N $IHOSTS 2>/dev/null || true; \
iptables -t nat -F $IHOSTS; \
iptables -t nat -A $IHOSTS -d 0.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 10.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 172.16.0.0/12 -j RETURN; \
iptables -t nat -A $IHOSTS -d 192.168.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -d 169.254.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -p tcp ! -d 224.0.0.0/4 -m set --match-set $IHOSTS dst -m multiport --dports 80,443 -j REDIRECT --to-ports $PORT; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c 'iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null || true; iptables -t nat -F $IHOSTS 2>/dev/null || true; iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now byedpi-hosts.timer >/dev/null 2>&1 || warn "Не удалось включить таймер hostlist"
    sudo "$UP" || warn "Не удалось заполнить ipset сразу"
    sudo systemctl enable --now byedpi-redirect >/dev/null 2>&1 || warn "Не удалось включить REDIRECT"
  fi
fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════"
echo "  ByeDPI: scope=$SCOPE метод=$METHOD порт=$PORT"
echo "═══════════════════════════════════════════════════════════"
echo "Конфиг:   $CFG"
echo "Hostlist: $HOSTS"
if [ "$METHOD" = "ipset" ]; then
  echo "Обрабатываются ТОЛЬКО домены из hostlist (ipset=$IHOSTS)."
  echo "  Правка: nano $HOSTS; затем $0 --status / перезапуск сервисов."
  echo "  Обновить ipset вручную: sudo $UP"
elif [ "$SCOPE" = "system" ]; then
  echo "SOCKS-прокси: 127.0.0.1:$PORT (расширения FoxyProxy/SmartProxy/SwitchyOmega 3)."
  echo "Бэкап Omega: ZeroOmegaOptions-*.bak в репозитории."
else
  echo "SOCKS-прокси: 127.0.0.1:$PORT (только для этого пользователя)."
  echo "Настройте расширение на этот порт."
fi
[ "$SCOPE" = "user" ] && echo "Автозапуск при входе включён. Для запуска без входа в сессию: sudo loginctl enable-linger $USER"