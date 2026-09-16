#!/bin/sh
#
# ByeDPI installer (ALT Linux / Sisyphus)
#
# Та же архитектура, что и autoinstall_byedpi_archlinux: раздельные файлы
# rule/port/hosts + управляющий conf с переменными-указателями, демон через
# launcher /usr/local/bin/byedpi-start, автотест стратегий desync.
#
# Режимы:
#   --system  — для всех пользователей (конфиг /etc/byedpi/conf)
#   --user    — только для текущего пользователя (конфиг ~/.config/byedpi/conf;
#               ipset: root-демон byedpi-<uid> + REDIRECT по --uid-owner;
#               extension: systemd-USER сервис)
#
# Методы:
#   --ipset      — без расширений: iptables REDIRECT всего TCP 80/443 в ByeDPI,
#                  фильтр доменов по SNI (--hosts), работает для CDN.
#   --extension  — SOCKS-прокси 127.0.0.1:порт для браузерного расширения.
#
# Права root: скрипт не запускается от root. Если нет sudo (стандарт для
# ALT) — повышение прав через `su -s /bin/sh -c '...' root` (вводится пароль
# root). Если sudo есть — используется sudo.
#
# Демон: через systemd, если он используется, иначе /etc/init.d/byedpi.
#
set -u

usage(){
  cat <<EOF
Использование: $0 [--system|--user] [--ipset|--extension] [--off|--status|--test] [--port N] [--no-test]
  --system        установить для всех пользователей (конфиг /etc/byedpi/)
  --user          установить только для текущего пользователя
  --ipset         метод ipset: весь TCP 80/443 через ByeDPI, фильтр по SNI
  --extension     метод extension: SOCKS-прокси для браузерного расширения
  --test          перезапустить автотест стратегий и обновить rule
  --no-test       пропустить автотест стратегий при установке
  --off | --remove  отключить, удалить сервисы, правила и конфиги
  --status|--info   показать текущее состояние
  --port N        изменить порт
  --socks         = --system --extension (старая совместимость)
  --transparent   = --system --ipset (старая совместимость)
  --transparent-off = --off
EOF
  exit 0
}

log_ok(){ echo "[OK] $*"; }
log_warn(){ echo "[WARN] $*"; }
log_err(){ echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Аргументы
# ---------------------------------------------------------------------------
SCOPE=""           # system | user
METHOD=""          # ipset | extension
ACTION="install"   # install | off | status | test
ARG_PORT=""
NO_TEST=""

for a in "$@"; do
  case "$a" in
    --system)     SCOPE=system ;;
    --user)       SCOPE=user ;;
    --ipset)      METHOD=ipset ;;
    --extension)  METHOD=extension ;;
    --off|--remove) ACTION=off ;;
    --status|--info) ACTION=status ;;
    --test|--retest) ACTION=test ;;
    --no-test)    NO_TEST=1 ;;
    --help|-h)    usage ;;
    --port=*)     ARG_PORT="${a#*=}" ;;
    --socks)      SCOPE=system; METHOD=extension ;;
    --transparent) SCOPE=system; METHOD=ipset ;;
    --transparent-off) ACTION=off ;;
    *) log_err "Неизвестный аргумент: $a (см. $0 --help)" ;;
  esac
done

if [ "$ACTION" = "install" ]; then
  [ -z "$SCOPE" ] && SCOPE=system
  [ -z "$METHOD" ] && METHOD=extension
fi
UID_NUM=$(id -u)

# ---------------------------------------------------------------------------
# Подъём прав: root → sudo → su (ALT обычно без sudo)
# ---------------------------------------------------------------------------
run_root(){ # строка-команда
  if [ "$(id -u)" -eq 0 ]; then
    /bin/sh -c "$1"
  elif command -v sudo >/dev/null 2>&1; then
    sudo /bin/sh -c "$1"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh -c "$1" root
  else
    log_err "Нужны права root (нет ни sudo, ни su)."
  fi
}

# ---------------------------------------------------------------------------
# Пути по режиму
# ---------------------------------------------------------------------------
if [ "$SCOPE" = "user" ]; then
  DIR="$HOME/.config/byedpi"
  IHOSTS="BYEDPI_$UID_NUM"
  PORT=$(( 14228 + UID_NUM - 1000 ))
else
  DIR="/etc/byedpi"
  IHOSTS="BYEDPI_HOSTS"
  PORT=14228
fi
[ -n "$ARG_PORT" ] && PORT="$ARG_PORT"
CFG="$DIR/conf"
PORT_FILE="$DIR/port"
RULE_FILE="$DIR/rule"
HOSTS_FILE="$DIR/hosts"
LAUNCHER=/usr/local/bin/byedpi-start
CIADPI=/usr/bin/ciadpi
DESYNC_ACTIVE="-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1"
DESYNC_FALLBACK=""
RULE="$DESYNC_ACTIVE $DESYNC_FALLBACK"

# ---------------------------------------------------------------------------
# Установка ciadpi: пакет byedpi из ALT-репозитория, иначе бинарник с GitHub
# ---------------------------------------------------------------------------
install_packages(){
  [ -x "$CIADPI" ] || CIADPI=/usr/local/bin/ciadpi
  if [ ! -x "$CIADPI" ]; then
    log_ok "Пробую поставить пакет byedpi (apt-get)..."
    run_root "apt-get update -y >/dev/null 2>&1 || true"
    run_root "apt-get install -y byedpi >/dev/null 2>&1 || true"
  fi
  if [ ! -x "$CIADPI" ]; then
    log_warn "Пакета нет — скачиваю ciadpi с GitHub (hufrea/byedpi releases)."
    case "$(uname -m)" in
      x86_64)        ARCH=x86_64 ;;
      aarch64|arm64) ARCH=aarch64 ;;
      armv7*|armhf)  ARCH=armv7l ;;
      armv6*)        ARCH=armv6 ;;
      i686|x86)      ARCH=i686 ;;
      mips)          ARCH=mips ;;
      mipsel)        ARCH=mipsel ;;
      powerpc|ppc*)  ARCH=powerpc ;;
      *) log_err "Незнакомая архитектура: $(uname -m)" ;;
    esac
    latest=$(curl -fsSL --max-time 20 https://api.github.com/repos/hufrea/byedpi/releases/latest 2>/dev/null \
             | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$latest" ] || latest=v0.17.3
    ver=$(printf '%s' "$latest" | tr -d 'v')
    url="https://github.com/hufrea/byedpi/releases/download/$latest/byedpi-$ver-$ARCH.tar.gz"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
    log_ok "Скачиваю: $url"
    curl -fsSL --max-time 120 -o "$tmpdir/byedpi.tgz" "$url" || log_err "Не удалось скачать $url"
    tar -xzf "$tmpdir/byedpi.tgz" -C "$tmpdir" || log_err "Не удалось распаковать архив"
    bin=$(find "$tmpdir" -maxdepth 1 -type f -name 'ciadpi*' | head -1)
    [ -n "$bin" ] || log_err "В архиве нет ciadpi"
    run_root "install -m 755 '$bin' /usr/local/bin/ciadpi"
    trap - EXIT HUP INT TERM
    rm -rf "$tmpdir"
    CIADPI=/usr/local/bin/ciadpi
  fi
  [ -x "$CIADPI" ] || log_err "ciadpi не найден: $CIADPI"
  log_ok "Бинарь ciadpi: $CIADPI"
}

# ---------------------------------------------------------------------------
# Автотест стратегий
# ---------------------------------------------------------------------------
TEST_PROBES="i.ytimg.com pbs.twimg.com yt3.ggpht.com www.youtube.com discord.com rutracker.org x.com www.instagram.com"

TEST_RULES="\
long-strategy|-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1
tlsrec-disorder|-Kt,h --tlsrec 1+s --disorder 1 --auto=torst --timeout 3
fake-found|-Kt,h --fake -1 --md5sig --auto=torst --timeout 3
disorder-1|-Kt,h --disorder 1 --auto=torst --timeout 3
split-1|-Kt,h --split 1+s --disorder 3+s --auto=torst --timeout 3
tlsrec-3|-Kt,h --tlsrec 3+s --auto=torst --timeout 3
base-long|-Kt,h -s0 -o1 -Ar -o1 -At -f-1 --md5sig -r1+s -As,n -Ku -a5 -An"

test_strategies(){ # hostlist-файл -> on stdout лучшее правило; прогресс в stderr
    hosts="$1"
    [ -f "$hosts" ] || log_err "Нет hostlist: $hosts"
    command -v curl >/dev/null 2>&1 || log_err "Для автотеста нужно curl"
    [ -x "$CIADPI" ] || log_err "Нет ciadpi: $CIADPI"

    tport=$(( 14600 + ($$ % 250) ))
    resfile="/tmp/byedpi-test-$$.res"
    pdir="/tmp/byedpi-probes-$$"
    mkdir -p "$pdir"
    > "$resfile"

    echo "=== Автотест стратегий desync ===" >&2
    echo "Пробы: $TEST_PROBES" >&2
    printf '%b\n' "$TEST_RULES" | while IFS='|' read -r name rule; do
      [ -n "$rule" ] || continue
      "$CIADPI" -H "$hosts" -i 127.0.0.1 --port "$tport" $rule >/dev/null 2>&1 &
      cpid=$!
      sleep 0.6
      i=0
      curls=""
      for h in $TEST_PROBES; do
        i=$((i+1))
        ( code=$(curl -k -sS -m 4 --socks5-hostname 127.0.0.1:"$tport" -o /dev/null -w "%{http_code}" "https://$h/" 2>/dev/null)
          echo "$code" > "$pdir/$i" ) &
        curls="$curls $!"
      done
      wait $curls
      kill "$cpid" 2>/dev/null
      wait "$cpid" 2>/dev/null
      ok=0; total=0
      for f in "$pdir"/*; do
        [ -f "$f" ] || continue
        total=$((total+1))
        code=$(cat "$f")
        if [ -n "$code" ] && [ "$code" != "000" ]; then ok=$((ok+1)); fi
      done
      echo "  [$name] $rule  →  открылось $ok из $total" >&2
      echo "$name|$ok|$total|$rule" >> "$resfile"
    done
    rm -rf "$pdir"

    best=""; bname=""; bscore=-1; btotal=0
    while IFS='|' read -r name score total rule; do
      if [ "${score:-0}" -gt "$bscore" ]; then
        bscore=$score; btotal=$total; bname=$name; best=$rule
      fi
    done < "$resfile"
    rm -f "$resfile"

    if [ -z "$best" ]; then
      log_warn "Ни одно правило не открыло ни одного домена (проверьте сеть/DNS)." >&2
      echo "$DESYNC_ACTIVE $DESYNC_FALLBACK"
      return 0
    fi
    echo "=== Лучшая стратегия: [$bname] → открылось $bscore из $btotal ===" >&2
    echo "$best"
}

# ---------------------------------------------------------------------------
# Запись файлов
# ---------------------------------------------------------------------------
wfile_root(){ # путь, содержимое — root нужен только для системных путей
  case "$1" in
    "$HOME"/*)
      mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
      ;;
    *)
      run_root "mkdir -p '$(dirname "$1")'; printf '%s\\n' '$2' > '$1'"
      ;;
  esac
}

write_port(){
  if [ -f "$PORT_FILE" ]; then
    if [ -n "$ARG_PORT" ]; then
      wfile_root "$PORT_FILE" "$PORT"
      log_warn "Порт обновлён: $PORT_FILE → $PORT"
    else
      PORT=$(grep -E '^[0-9]+$' "$PORT_FILE" | head -1)
      [ -z "$PORT" ] && { PORT=14228; wfile_root "$PORT_FILE" "$PORT"; }
      log_ok "Порт (из файла): $PORT"
    fi
  else
    wfile_root "$PORT_FILE" "$PORT"
    log_ok "Порт: $PORT_FILE → $PORT"
  fi
}

write_hostlist(){
  if [ -f "$HOSTS_FILE" ]; then
    log_warn "Hostlist уже есть, не перезаписан: $HOSTS_FILE"
    return 0
  fi
  run_root "mkdir -p '$DIR'"
  cat > /tmp/byedpi-hosts.$$ <<'EOL'
# ByeDPI hostlist — домены, к которым применяется desync.
# Список синхронизирован с расширением ZeroOmega (55 доменов).
# Формат: один домен на строку, строки с # игнорируются.
# Правка: отредактируйте и перезапустите сервисы (см. README).
cdnbunny.org
youtube.com
googlevideo.com
play.google.com
yt3.ggpht.com
youtu.be
rutor.info
rutracker.org
rutracker.cc
nnmclub.to
habr.com
instagram.com
archlinuxgui.in
sourceforge.net
scontent-hel3-1.cdninstagram.com
cdninstagram.com
ntc.party
discord.com
discord.gg
opera.com
discordapp.com
discordapp.net
discord.media
discord-attachments-uploads-prd.storage.googleapis.com
dis.gd
discord.co
discordcdn.com
discordstatus.com
proton.me
twimg.com
torproject.org
archive.org
web.archive.org
soundcloud.com
mullvad.net
roskomsvoboda.org
medium.com
hybrid-analysis.com
4pda.to
chatgpt.com
facebook.com
bbc.com
addons.opera.com
twitter.com
holod.media
news.google.com
flibusta.lib
flibusta.is
flibusta.info
linkedin.com
t.co
x.com
ytimg.com
yt3.googleusercontent.com
ggpht.com
EOL
  case "$HOSTS_FILE" in
    "$HOME"/*) tee "$HOSTS_FILE" > /dev/null < /tmp/byedpi-hosts.$$ ;;
    *)         run_root "tee '$HOSTS_FILE' > /dev/null < /tmp/byedpi-hosts.$$" ;;
  esac
  rm -f /tmp/byedpi-hosts.$$
  log_ok "Создан hostlist: $HOSTS_FILE"
}

write_rule(){
  if [ -f "$RULE_FILE" ]; then
    log_ok "Правило уже есть, не перезаписано: $RULE_FILE"
    return 0
  fi
  if [ -z "$NO_TEST" ]; then
    best=$(test_strategies "$HOSTS_FILE")
    [ -n "$best" ] && RULE="$best"
  fi
  wfile_root "$RULE_FILE" "$RULE"
  log_ok "Правило desync: $RULE_FILE"
}

write_conf(){
  if [ "$METHOD" = "ipset" ]; then MODE=transparent; else MODE=socks; fi
  if [ -f "$CFG" ] && grep -Fq "BYEDPI_MODE=\"$MODE\"" "$CFG"; then
    log_ok "Конфиг уже есть, не перезаписан: $CFG"
    return 0
  fi
  wfile_root "$CFG" "BYEDPI_MODE=\"$MODE\"
# ByeDPI — управляющий конфиг. Порт/правило/список доменов лежат в файлах,
# на которые указывают переменные ниже.
BYEDPI_BIND=\"127.0.0.1\"
BYEDPI_PORT_FILE=\"$PORT_FILE\"
BYEDPI_RULE_FILE=\"$RULE_FILE\"
BYEDPI_HOSTS_FILE=\"$HOSTS_FILE\""
  log_ok "Конфиг: $CFG"
}

write_launcher(){
  run_root "mkdir -p /usr/local/bin"
  cat > /tmp/byedpi-launcher.$$ <<'EOF'
#!/bin/sh
# ByeDPI launcher: собирает опции ciadpi из отдельных файлов конфига.
# Использование: byedpi-start [путь/conf]   (по умолчанию /etc/byedpi/conf)
set -u
CFG="${1:-/etc/byedpi/conf}"
[ -f "$CFG" ] || { echo "byedpi-start: нет конфига $CFG" >&2; exit 1; }
. "$CFG"

for v in BYEDPI_PORT_FILE BYEDPI_RULE_FILE BYEDPI_HOSTS_FILE; do
  eval "f=\${$v:-}"
  [ -n "$f" ] || { echo "byedpi-start: в $CFG не задано $v" >&2; exit 1; }
  [ -r "$f" ] || { echo "byedpi-start: нет файла $v = $f" >&2; exit 1; }
done

CIADPI_BIN="${BYEDPI_BIN:-}"
[ -n "$CIADPI_BIN" ] || CIADPI_BIN=$(command -v ciadpi 2>/dev/null || echo /usr/local/bin/ciadpi)
[ -x "$CIADPI_BIN" ] || { echo "byedpi-start: нет ciadpi ($CIADPI_BIN)" >&2; exit 1; }

BIND="${BYEDPI_BIND:-127.0.0.1}"
PORT="$(cat "$BYEDPI_PORT_FILE")"
RULE="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$BYEDPI_RULE_FILE")"
case "${BYEDPI_MODE:-socks}" in
  transparent) exec "$CIADPI_BIN" -E -H "$BYEDPI_HOSTS_FILE" -i "$BIND" --port "$PORT" $RULE ;;
  socks)       exec "$CIADPI_BIN" -i "$BIND" --port "$PORT" $RULE ;;
  *) echo "byedpi-start: неизвестный BYEDPI_MODE=$BYEDPI_MODE" >&2; exit 1 ;;
esac
EOF
  run_root "install -m 755 /tmp/byedpi-launcher.$$ $LAUNCHER"
  rm -f /tmp/byedpi-launcher.$$
  log_ok "Launcher: $LAUNCHER"
}

# ---------------------------------------------------------------------------
# systemd (если используется) или init.d
# ---------------------------------------------------------------------------
SYSTEMD=no
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && SYSTEMD=yes

daemon_restart(){
  if [ "$SCOPE" = "user" ] && [ "$METHOD" = "extension" ] && [ -f "$HOME/.config/systemd/user/byedpi.service" ]; then
    systemctl --user restart byedpi || true
  elif [ -f "/etc/systemd/system/byedpi-$UID_NUM.service" ]; then
    run_root "systemctl restart byedpi-$UID_NUM || true"
  elif [ -f /etc/systemd/system/byedpi.service ]; then
    run_root "systemctl restart byedpi || true"
  elif [ -f /etc/init.d/byedpi ]; then
    run_root "/etc/init.d/byedpi restart || true"
  else
    log_warn "Демон не перезапущен — юнит не установлен."
    return 0
  fi
  log_ok "Демон перезапущен."
}

write_units(){
  if [ "$METHOD" = "ipset" ] && [ "$SCOPE" = "user" ]; then
    # В прозрачном режиме демон обязан работать под root (иначе его же
    # исходящие соединения попали бы под собственный REDIRECT).
    run_root "mkdir -p /etc/systemd/system"
    cat > /tmp/byedpi-unit.$$ <<EOF
[Unit]
Description=ByeDPI transparent (user $USER)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LAUNCHER $HOME/.config/byedpi/conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    run_root "install -m 644 /tmp/byedpi-unit.$$ /etc/systemd/system/byedpi-$UID_NUM.service"
    rm -f /tmp/byedpi-unit.$$
    cat > /tmp/byedpi-redirect.$$ <<EOF
[Unit]
Description=ByeDPI REDIRECT (uid $UID_NUM)
Wants=byedpi-$UID_NUM.service
After=byedpi-$UID_NUM.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
. $HOME/.config/byedpi/conf; \
P="\$(cat "\$BYEDPI_PORT_FILE")"; \
iptables -t nat -N $IHOSTS 2>/dev/null || true; \
iptables -t nat -F $IHOSTS; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 0.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 10.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 172.16.0.0/12 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 192.168.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -d 169.254.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -m owner --uid-owner $UID_NUM -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports "\$P"; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c 'iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null || true; iptables -t nat -F $IHOSTS 2>/dev/null || true; iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    run_root "install -m 644 /tmp/byedpi-redirect.$$ /etc/systemd/system/byedpi-redirect-$UID_NUM.service"
    rm -f /tmp/byedpi-redirect.$$
    run_root "systemctl daemon-reload"
    run_root "systemctl enable --now byedpi-$UID_NUM.service >/dev/null 2>&1 || true"
    run_root "systemctl enable --now byedpi-redirect-$UID_NUM.service >/dev/null 2>&1 || true"
    log_ok "Root-демон:  /etc/systemd/system/byedpi-$UID_NUM.service"
    log_ok "REDIRECT:    /etc/systemd/system/byedpi-redirect-$UID_NUM.service"
  elif [ "$METHOD" = "extension" ] && [ "$SCOPE" = "user" ]; then
    [ "$SYSTEMD" = "yes" ] || log_err "Метод extension для user требует systemd."
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/byedpi.service" <<EOF
[Unit]
Description=ByeDPI (user $USER)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LAUNCHER %h/.config/byedpi/conf
Restart=on-failure

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now byedpi >/dev/null 2>&1 || log_warn "user unit не запустился сразу (включится при входе)"
    log_ok "Юзер-сервис: ~/.config/systemd/user/byedpi.service"
  else
    # system scope
    if [ "$SYSTEMD" = "yes" ]; then
      run_root "mkdir -p /etc/systemd/system"
      cat > /tmp/byedpi-unit.$$ <<EOF
[Unit]
Description=ByeDPI
Documentation=https://github.com/hufrea/byedpi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LAUNCHER $CFG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      run_root "install -m 644 /tmp/byedpi-unit.$$ /etc/systemd/system/byedpi.service"
      rm -f /tmp/byedpi-unit.$$
      run_root "systemctl daemon-reload"
      run_root "systemctl enable --now byedpi >/dev/null 2>&1 || true"
      log_ok "systemd: byedpi.service"
    else
      cat > /tmp/byedpi-initd.$$ <<EOF
#!/bin/sh
# ByeDPI init-скрипт (без systemd).
CFG=$CFG
LAUNCHER=$LAUNCHER
IHOSTS=$IHOSTS
start(){
  [ -f /run/byedpi.pid ] && { echo "ByeDPI уже работает"; return 0; }
  "$LAUNCHER" "\$CFG" > /var/log/byedpi.log 2>&1 &
  echo \$! > /run/byedpi.pid
  if grep -q 'transparent' "\$CFG"; then
    P="\$(cat "\$(sed -n 's/^BYEDPI_PORT_FILE="\([^"]*\)".*/\1/p' "\$CFG")")"
    iptables -t nat -N "\$IHOSTS" 2>/dev/null || true
    iptables -t nat -F "\$IHOSTS"
    iptables -t nat -A "\$IHOSTS" -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A "\$IHOSTS" -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A "\$IHOSTS" -p tcp -m owner ! --uid-owner 0 -m multiport --dports 80,443 -j REDIRECT --to-ports "\$P"
    iptables -t nat -A OUTPUT -j "\$IHOSTS"
  fi
}
stop(){
  [ -f /run/byedpi.pid ] && kill \$(cat /run/byedpi.pid) 2>/dev/null
  rm -f /run/byedpi.pid
  iptables -t nat -D OUTPUT -j "\$IHOSTS" 2>/dev/null || true
  iptables -t nat -F "\$IHOSTS" 2>/dev/null || true
  iptables -t nat -X "\$IHOSTS" 2>/dev/null || true
}
case "\$1" in
  start) start ;;
  stop)  stop ;;
  restart|force-reload) stop; sleep 1; start ;;
  status) pgrep -f "ciadpi.*--port" >/dev/null && echo "ByeDPI: работает" || echo "ByeDPI: не работает" ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
      run_root "install -m 755 /tmp/byedpi-initd.$$ /etc/init.d/byedpi"
      rm -f /tmp/byedpi-initd.$$
      log_ok "init-скрипт: /etc/init.d/byedpi (systemd не используется)"
    fi
    if [ "$METHOD" = "ipset" ]; then
      if [ "$SYSTEMD" = "yes" ]; then
        cat > /tmp/byedpi-redirect.$$ <<EOF
[Unit]
Description=ByeDPI transparent redirect rules (SNI через --hosts)
Wants=byedpi.service
After=byedpi.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
. $CFG; \
P="\$(cat "\$BYEDPI_PORT_FILE")"; \
iptables -t nat -N $IHOSTS 2>/dev/null || true; \
iptables -t nat -F $IHOSTS; \
iptables -t nat -A $IHOSTS -d 0.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 10.0.0.0/8 -j RETURN; \
iptables -t nat -A $IHOSTS -d 172.16.0.0/12 -j RETURN; \
iptables -t nat -A $IHOSTS -d 192.168.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -d 169.254.0.0/16 -j RETURN; \
iptables -t nat -A $IHOSTS -p tcp -m owner ! --uid-owner 0 -m multiport --dports 80,443 -j REDIRECT --to-ports "\$P"; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c 'iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null || true; iptables -t nat -F $IHOSTS 2>/dev/null || true; iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
        run_root "install -m 644 /tmp/byedpi-redirect.$$ /etc/systemd/system/byedpi-redirect.service"
        rm -f /tmp/byedpi-redirect.$$
        run_root "systemctl daemon-reload"
        run_root "systemctl enable --now byedpi-redirect >/dev/null 2>&1 || true"
      fi
      log_ok "REDIRECT: ipset-правила (iptables)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# status / off / test
# ---------------------------------------------------------------------------
cmd_status(){
  echo "=== ByeDPI: статус ==="
  if [ -f "/etc/systemd/system/byedpi-$UID_NUM.service" ]; then
    echo "-- transparent (root): byedpi-$UID_NUM.service --"
    run_root "systemctl --no-pager status byedpi-$UID_NUM 2>/dev/null | head -8 || true" || true
    [ -f "/etc/systemd/system/byedpi-redirect-$UID_NUM.service" ] && \
      run_root "systemctl --no-pager status byedpi-redirect-$UID_NUM 2>/dev/null | head -4 || true" || true
  elif [ -f /etc/systemd/system/byedpi.service ]; then
    echo "-- system: byedpi.service --"
    run_root "systemctl --no-pager status byedpi 2>/dev/null | head -8 || true" || true
    [ -f /etc/systemd/system/byedpi-redirect.service ] && \
      run_root "systemctl --no-pager status byedpi-redirect 2>/dev/null | head -4 || true" || true
  elif [ -f "$HOME/.config/systemd/user/byedpi.service" ]; then
    echo "-- SOCKS (user): byedpi.service --"
    systemctl --user --no-pager status byedpi 2>/dev/null | head -8 || true
  elif [ -f /etc/init.d/byedpi ]; then
    /etc/init.d/byedpi status 2>/dev/null || true
  else
    echo "ByeDPI НЕ установлен (ни один юнит не найден)"
  fi
  [ -f "$HOME/.config/byedpi/conf" ] && { echo "user config:   ~/.config/byedpi/conf";   [ -f "$HOME/.config/byedpi/rule" ] && echo "user rule:     $(cat "$HOME/.config/byedpi/rule")";   [ -f "$HOME/.config/byedpi/port" ] && echo "user port:     $(cat "$HOME/.config/byedpi/port")"; }
  [ -f /etc/byedpi/conf ] && { echo "system config: /etc/byedpi/conf";        [ -f /etc/byedpi/rule ] && echo "system rule:   $(cat /etc/byedpi/rule)";          [ -f /etc/byedpi/port ] && echo "system port:   $(cat /etc/byedpi/port)"; }
  exit 0
}

cmd_off(){
  echo "=== Отключение ByeDPI ==="
  systemctl --user disable --now byedpi.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/byedpi.service"

  for n in "byedpi" "byedpi-$UID_NUM" "byedpi-redirect" "byedpi-redirect-$UID_NUM"; do
    run_root "systemctl disable --now $n 2>/dev/null || true"
  done
  run_root "rm -f /etc/systemd/system/byedpi.service /etc/systemd/system/byedpi-$UID_NUM.service /etc/systemd/system/byedpi-redirect.service /etc/systemd/system/byedpi-redirect-$UID_NUM.service; systemctl daemon-reload 2>/dev/null || true"
  run_root "rm -f /etc/init.d/byedpi"

  run_root "iptables -t nat -D OUTPUT -j BYEDPI 2>/dev/null || true"
  run_root "iptables -t nat -D OUTPUT -j BYEDPI_HOSTS 2>/dev/null || true"
  run_root "iptables -t nat -D OUTPUT -j BYEDPI_$UID_NUM 2>/dev/null || true"
  run_root "iptables -t nat -F BYEDPI 2>/dev/null || true; iptables -t nat -F BYEDPI_HOSTS 2>/dev/null || true; iptables -t nat -F BYEDPI_$UID_NUM 2>/dev/null || true; iptables -t nat -X BYEDPI 2>/dev/null || true; iptables -t nat -X BYEDPI_HOSTS 2>/dev/null || true; iptables -t nat -X BYEDPI_$UID_NUM 2>/dev/null || true"

  run_root "rm -rf /etc/byedpi $LAUNCHER /usr/local/bin/byedpi"
  rm -rf "$HOME/.config/byedpi"
  run_root "rm -f /etc/sysconfig/byedpi /etc/byedpi-hosts.txt /usr/local/bin/byedpi-hosts-update.sh /usr/local/bin/byedpi-hosts-update-$UID_NUM.sh"
  rm -f "$HOME/.config/byedpi.conf" "$HOME/.config/byedpi-hosts.txt"
  echo "ByeDPI отключён. Конфиги и hostlist удалены."
  exit 0
}

cmd_test(){
  [ -f "$HOSTS_FILE" ] || log_err "Нет hostlist: $HOSTS_FILE (сначала установите ByeDPI)."
  best=$(test_strategies "$HOSTS_FILE")
  wfile_root "$RULE_FILE" "$best"
  log_ok "Правило записано: $RULE_FILE"
  daemon_restart
}

# ---------------------------------------------------------------------------
# Главный запуск
# ---------------------------------------------------------------------------
case "$ACTION" in
  status) cmd_status ;;
  off)    cmd_off ;;
  test)   cmd_test ;;
  install)
    install_packages
    write_port
    write_hostlist
    write_rule
    write_conf
    write_launcher
    write_units
    daemon_restart
    echo "═══════════════════════════════════════════════════════════"
    echo "  ByeDPI (ALT Linux): scope=$SCOPE метод=$METHOD порт=$PORT"
    echo "═══════════════════════════════════════════════════════════"
    echo "Каталог:  $DIR"
    echo "Правка:   nano $DIR/hosts (или rule/port); перезапуск демона: $LAUNCHER"
    echo "Пересборка правила: $0 --test"
    [ "$SCOPE" = "user" ] && [ "$METHOD" = "extension" ] && echo "Автозапуск при входе включён. Для запуска без входа в сессию: su -s /bin/sh -c 'loginctl enable-linger $USER' root"
    ;;
esac