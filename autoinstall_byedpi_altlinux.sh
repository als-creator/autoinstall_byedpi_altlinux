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
Использование: $0 [--system|--user] [--ipset|--extension] [--off|--status|--test|--check|--update] [--port N] [--no-test] [--keep-files]
  --system        установить для всех пользователей (конфиг /etc/byedpi/)
  --user          установить только для текущего пользователя
  --ipset         метод ipset: весь TCP 80/443 через ByeDPI, фильтр по SNI
  --extension     метод extension: SOCKS-прокси для браузерного расширения
  --test          перезапустить автотест стратегий и обновить rule
  --check         проверить минимальный набор доменов (rutracker/nnm-club/
                  youtube/discord) и сказать, что именно не открывается
  --no-test       пропустить автотест стратегий при установке
  --keep-files    не трогать существующие hosts/rule (по умолчанию они
                  перезаписываются версией из скрипта, старое -> .bak-<дата>)
  --keep-package  не удалять пакет byedpi при --off (по умолчанию удаляется
                  вместе с сервисом и конфигом)
  --block-quic    блокировать UDP 443 (QUIC): браузер сразу идёт по TCP через
                  ByeDPI, без чёрного экрана на время таймаута HTTP/3
                  (по умолчанию включено для transparent)
  --allow-quic    не блокировать QUIC (вернуть прежнее поведение)
  --update        обновить hosts/rule/launcher/юнит из скрипта и перезапустить
  --off | --remove  отключить, удалить сервисы, правила, конфиги и byedpi
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
ACTION="install"   # install | update | off | status | test | check
KEEP_FILES=""      # --keep-files: не перезаписывать существующие hosts/rule
KEEP_PACKAGE=""    # --keep-package: не удалять пакет byedpi при --off
BLOCK_QUIC=""      # yes|no; пусто — взять из conf или по умолчанию (transparent: yes)
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
    --check)    ACTION=check ;;
    --update|--upgrade) ACTION=update ;;
    --keep-files) KEEP_FILES=1 ;;
    --keep-package) KEEP_PACKAGE=1 ;;
    --block-quic) BLOCK_QUIC=yes ;;
    --allow-quic) BLOCK_QUIC=no ;;
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
  [ -z "$METHOD" ] && METHOD=ipset
fi
UID_NUM=$(id -u)

# Имена ресурсов блокировки QUIC: у прозрачного режима user-scope отдельная
# цепочка на uid, чтобы правила разных пользователей не пересекались.
if [ "$SCOPE" = "user" ]; then
  QCHAIN="BYEDPI_QUIC_$UID_NUM"
  QUNIT="byedpi-quic-$UID_NUM"
  QMATCH="-m owner --uid-owner $UID_NUM"
else
  QCHAIN="BYEDPI_QUIC"
  QUNIT="byedpi-quic"
  QMATCH="-m owner ! --uid-owner 0"
fi

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
      x86_64)        ARCH=x86_64;  TOKS="x86_64 amd64" ;;
      aarch64|arm64) ARCH=aarch64; TOKS="aarch64 arm64" ;;
      armv7*|armhf)  ARCH=armv7l;  TOKS="armv7l armv7 armhf" ;;
      armv6*)        ARCH=armv6;   TOKS="armv6" ;;
      i686|x86)      ARCH=i686;    TOKS="i686 386" ;;
      mips)          ARCH=mips;    TOKS="mips" ;;
      mipsel)        ARCH=mipsel;  TOKS="mipsel" ;;
      powerpc|ppc*)  ARCH=powerpc; TOKS="powerpc ppc" ;;
      *) log_err "Незнакомая архитектура: $(uname -m)" ;;
    esac
    api=$(curl -fsSL --max-time 30 https://api.github.com/repos/hufrea/byedpi/releases/latest 2>/dev/null || true)
    latest=$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$latest" ] || latest=v0.17.3
    urls=""
    for tok in $TOKS; do
      u=$(printf '%s' "$api" \
          | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | sed 's/.*"\(https[^"]*\)".*/\1/' \
          | grep -i -- "$tok" | grep -Ei '\.(tar\.gz|tgz)$' | head -1)
      [ -n "$u" ] && { urls="$u"; break; }
    done
    if [ -z "$urls" ]; then
      ver=$(printf '%s' "$latest" | tr -d 'v')
      urls="https://github.com/hufrea/byedpi/releases/download/$latest/byedpi-${ver#0.}-$ARCH.tar.gz
            https://github.com/hufrea/byedpi/releases/download/$latest/byedpi-$ver-$ARCH.tar.gz"
    fi
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
    ok=
    for u in $urls; do
      log_ok "Скачиваю: $u"
      if curl -fsSL --max-time 120 -o "$tmpdir/byedpi.tgz" "$u"; then ok=1; break; fi
    done
    [ -n "$ok" ] || log_err "Не удалось скачать ciadpi (пробовал: $urls)"
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
probe_direct(){ # домен -> 0, если открывается "как есть" (без прокси).
    # 3 попытки: часть блокировок статистическая (DPI смотрит не все потоки).
    i=0
    while [ $i -lt 3 ]; do
        code=$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && return 0
        i=$((i+1)); sleep 0.5
    done
    return 1
}

# Минимальный набор доменов, который обязан открываться:
#   rutor / rutracker / nnm-club / youtube
# Именно по нему выбирается правило desync.
TEST_PROBES="rutracker.org nnmclub.to www.youtube.com i.ytimg.com yt3.googleusercontent.com discord.com"

TEST_RULES="\
long-strategy|-d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -r1+s -S -a1 -As -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -d35+s -S -a1
multisplit-d1|-Kt,h -d1 -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -s25+s -s30+s -s35+s -r1+s -S -a1 -As
disorder-sni|-Kt,h --disorder 1 -s0 -r1+s -f-1 -a5 -An
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
    rawdir="/tmp/byedpi-probes-$$"
    mkdir -p "$rawdir"
    > "$resfile"

    echo "=== Автотест стратегий desync ===" >&2
    echo "Минимальный набор: $TEST_PROBES" >&2
    printf '%b\n' "$TEST_RULES" | while IFS='|' read -r name rule; do
      [ -n "$rule" ] || continue
      "$CIADPI" -H "$hosts" -i 127.0.0.1 --port "$tport" $rule >/dev/null 2>&1 &
      cpid=$!
      sleep 0.6
      pdir="$rawdir/$name"
      rm -rf "$pdir"; mkdir -p "$pdir"
      i=0
      curls=""
      for h in $TEST_PROBES; do
        i=$((i+1))
        ( code=$(curl -k -sS -m 6 --socks5-hostname 127.0.0.1:"$tport" -o /dev/null -w "%{http_code}" "https://$h/" 2>/dev/null)
          echo "$code" > "$pdir/$i" ) &
        curls="$curls $!"
      done
      wait $curls
      kill "$cpid" 2>/dev/null
      wait "$cpid" 2>/dev/null
      ok=0; total=0; line=""
      for h in $TEST_PROBES; do
        total=$((total+1))
        code=$(cat "$pdir/$total" 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
          ok=$((ok+1)); line="$line $h=OK"
        else
          line="$line $h=FAIL"
        fi
      done
      printf '  [%-16s] %s\n' "$name" "$line" >&2
      echo "$name|$ok|$total|$rule" >> "$resfile"
    done

    # Домены, не открывшиеся НИ ОДНИМ правилом: скорее всего заблокированы по IP
    # (RST сразу после connect). desync по SNI такие блокировки не снимает.
    unreachable=""
    for h in $TEST_PROBES; do
      opened=0
      for d in "$rawdir"/*; do
        [ -d "$d" ] || continue
        idx=0
        for h2 in $TEST_PROBES; do
          idx=$((idx+1))
          [ "$h2" = "$h" ] || continue
          code=$(cat "$d/$idx" 2>/dev/null)
          [ -n "$code" ] && [ "$code" != "000" ] && opened=1
        done
      done
      [ "$opened" -eq 0 ] && unreachable="$unreachable $h"
    done
    if [ -n "$unreachable" ]; then
      log_warn "Не открылись ни одним правилом:$unreachable" >&2
      for h in $unreachable; do
        probe_direct "$h" && log_warn "  $h: напрямую открывается — домен не в списке desync ($HOSTS_FILE)" >&2 \
          || log_warn "  $h: напрямую тоже не открывается — вероятна блокировка по IP, нужен другой доступ" >&2
      done
    fi

    best=""; bname=""; bscore=-1; btotal=0
    while IFS='|' read -r name score total rule; do
      if [ "${score:-0}" -gt "$bscore" ]; then
        bscore=$score; btotal=$total; bname=$name; best=$rule
      fi
    done < "$resfile"
    rm -rf "$rawdir"
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

# Копия файла перед перезаписью: имя.bak-YYYYmmdd-HHMMSS.
backup_file(){ # путь -> путь к копии (stdout), код 1 если копии нет
    f="$1"
    [ -f "$f" ] || return 0
    b="$f.bak-$(date +%Y%m%d-%H%M%S)"
    case "$f" in
        "$HOME"/*) cp -p "$f" "$b" 2>/dev/null || cp "$f" "$b" 2>/dev/null || true ;;
        *)         run_root "cp -p '$f' '$b' 2>/dev/null || cp '$f' '$b' 2>/dev/null || true" ;;
    esac
    if [ -f "$b" ]; then
        echo "$b"; return 0
    fi
    log_warn "Не удалось создать резервную копию $f (нет прав?) — будет перезаписано без бэкапа" >&2
    echo ""
    return 1
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
  # По умолчанию список перезаписывается версией из скрипта (скрипт качается
  # с сервера), старое сохраняется в .bak-<дата>. --keep-files отменяет.
  if [ -f "$HOSTS_FILE" ]; then
    if [ -n "$KEEP_FILES" ]; then
      log_warn "Hostlist уже есть и --keep-files задан, не перезаписан: $HOSTS_FILE"
      return 0
    fi
    bak=$(backup_file "$HOSTS_FILE")
    [ -n "$bak" ] && log_warn "Hostlist обновляется из скрипта, предыдущий сохранён: $bak"
  fi
  run_root "mkdir -p '$DIR'"
  cat > /tmp/byedpi-hosts.$$ <<'EOL'
# ByeDPI hostlist — домены, к которым применяется desync.
# Формат: один домен на строку, строки с # игнорируются.
# Правка: отредактируйте и перезапустите сервисы (см. README).
#
# --- МИНИМУМ (проверяется командой `скрипт --check`) -----------------------
# Rutor
rutor.info
rutor.is
# Rutracker
rutracker.org
rutracker.cc
# NNM-Club
nnmclub.to
nnmclub.me
# YouTube (включая CDN-поддомены)
youtube.com
googlevideo.com
ytimg.com
ggpht.com
youtu.be
yt.be
play.google.com
youtubei.googleapis.com
youtube.googleapis.com
yt3.googleusercontent.com
news.google.com
gstatic.com
googleusercontent.com
l.google.com
1e100.net
m.youtube.com
img.youtube.com
yt3.ggpht.com
yt4.ggpht.com
youtube.ru
# Остальные домены (Discord, соцсети, архивы, обход блокировок)
cdnbunny.org
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
flibusta.lib
flibusta.is
flibusta.info
linkedin.com
t.co
# --- Заблокированные сервисы и медиа ---------------------------------------
# Проверено на живом провайдере: без desync соединение не устанавливается
# (curl = 000), с текущим правилом открываются.
signal.org
meduza.io
te-st.org
svoboda.org
currenttime.tv
novayagazeta.eu
ovdinfo.org
EOL
  case "$HOSTS_FILE" in
    "$HOME"/*) tee "$HOSTS_FILE" > /dev/null < /tmp/byedpi-hosts.$$ ;;
    *)         run_root "tee '$HOSTS_FILE' > /dev/null < /tmp/byedpi-hosts.$$" ;;
  esac
  rm -f /tmp/byedpi-hosts.$$
  log_ok "Hostlist записан: $HOSTS_FILE"
}

write_rule(){
  if [ -f "$RULE_FILE" ]; then
    if [ -n "$KEEP_FILES" ]; then
      log_ok "Правило уже есть и --keep-files задан, не перезаписано: $RULE_FILE"
      return 0
    fi
    bak=$(backup_file "$RULE_FILE")
    [ -n "$bak" ] && log_warn "Правило обновляется, предыдущее сохранено: $bak"
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
BYEDPI_HOSTS_FILE=\"$HOSTS_FILE\"
# Блокировка QUIC (UDP 443): браузер сразу идёт по TCP через ByeDPI.
BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\""
  log_ok "Конфиг: $CFG"
}

# ---------------------------------------------------------------------------
# QUIC (UDP 443)
#
# ByeDPI перехватывает только TCP (REDIRECT -p tcp). UDP 443 идёт мимо, и если
# провайдер его режет, браузер висит на HTTP/3 до таймаута: YouTube показывает
# чёрный экран/крутилку, хотя TCP через ByeDPI работает. Быстрый REJECT
# заставляет браузер сразу переключиться на TCP.
# ---------------------------------------------------------------------------
quic_flag_from_conf(){
  [ -f "$CFG" ] || return 1
  v=$(sed -n 's/^BYEDPI_BLOCK_QUIC="\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' "$CFG" | head -1)
  [ -n "$v" ] || return 1
  echo "$v"
}

# Итоговое значение: флаг из аргументов > значение из conf > по умолчанию.
# Блокировка требует root, поэтому она возможна только в transparent-режиме:
# в SOCKS-режиме QUIC не используется браузером при прокси.
resolve_quic_flag(){
  if [ -z "$BLOCK_QUIC" ]; then
    if [ "$ACTION" != "install" ] && v=$(quic_flag_from_conf); then
      BLOCK_QUIC=$v
    elif [ "$METHOD" = "ipset" ]; then
      BLOCK_QUIC=yes
    else
      BLOCK_QUIC=no
    fi
  fi
  if [ "$BLOCK_QUIC" = "yes" ] && [ "$METHOD" != "ipset" ]; then
    log_warn "QUIC блокируется только в transparent (--ipset); в SOCKS-режиме правило не нужно"
    BLOCK_QUIC=no
  fi
}

# Сохранить выбор в conf, чтобы --status/--check/--update его видели.
write_quic_flag(){
  [ -f "$CFG" ] || return 0
  cur=$(quic_flag_from_conf) || cur=""
  [ "$cur" = "$BLOCK_QUIC" ] && return 0
  if [ -n "$cur" ]; then
    run_root "sed -i 's|^BYEDPI_BLOCK_QUIC=.*|BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\"|' '$CFG'"
  else
    run_root "printf '%s\\n' 'BYEDPI_BLOCK_QUIC=\"$BLOCK_QUIC\"' >> '$CFG'"
  fi
}

# Юнит блокировки QUIC (только systemd; в init.d правило ставится напрямую).
write_quic_unit(){
  cat > /tmp/byedpi-quic.$$ <<EOF
[Unit]
Description=Block QUIC (UDP 443) so browsers use TCP through ByeDPI
Documentation=https://github.com/hufrea/byedpi
After=network-online.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
iptables -t filter -N $QCHAIN 2>/dev/null || true; \
iptables -t filter -F $QCHAIN; \
iptables -t filter -A $QCHAIN $QMATCH -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable; \
while iptables -t filter -D OUTPUT -j $QCHAIN 2>/dev/null; do :; done; iptables -t filter -A OUTPUT -j $QCHAIN'
ExecStop=/bin/sh -c '\
while iptables -t filter -D OUTPUT -j $QCHAIN 2>/dev/null; do :; done; \
iptables -t filter -F $QCHAIN 2>/dev/null || true; \
iptables -t filter -X $QCHAIN 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
  run_root "install -m 644 /tmp/byedpi-quic.$$ /etc/systemd/system/$QUNIT.service"
  rm -f /tmp/byedpi-quic.$$
  run_root "systemctl daemon-reload"
  run_root "systemctl enable --now $QUNIT >/dev/null 2>&1 || true"
  log_ok "QUIC:        /etc/systemd/system/$QUNIT.service (UDP 443 -> REJECT)"
}

remove_quic_unit(){
  run_root "systemctl disable --now $QUNIT 2>/dev/null || true"
  run_root "rm -f /etc/systemd/system/$QUNIT.service"
  run_root "systemctl daemon-reload"
  run_root "while iptables -t filter -D OUTPUT -j $QCHAIN 2>/dev/null; do :; done"
  run_root "iptables -t filter -F $QCHAIN 2>/dev/null || true"
  run_root "iptables -t filter -X $QCHAIN 2>/dev/null || true"
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
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c '\
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -F $IHOSTS 2>/dev/null || true; \
iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    run_root "install -m 644 /tmp/byedpi-redirect.$$ /etc/systemd/system/byedpi-redirect-$UID_NUM.service"
    rm -f /tmp/byedpi-redirect.$$
    run_root "systemctl daemon-reload"
    run_root "systemctl enable --now byedpi-$UID_NUM.service >/dev/null 2>&1 || true"
    run_root "systemctl enable --now byedpi-redirect-$UID_NUM.service >/dev/null 2>&1 || true"
    [ "$BLOCK_QUIC" = "yes" ] && write_quic_unit
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
      QUIC_START=""
      QUIC_STOP=""
      if [ "$BLOCK_QUIC" = "yes" ]; then
        QUIC_START="    iptables -t filter -N $QCHAIN 2>/dev/null || true; iptables -t filter -F $QCHAIN; iptables -t filter -A $QCHAIN $QMATCH -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable; while iptables -t filter -D OUTPUT -j $QCHAIN 2>/dev/null; do :; done; iptables -t filter -A OUTPUT -j $QCHAIN"
        QUIC_STOP="  while iptables -t filter -D OUTPUT -j $QCHAIN 2>/dev/null; do :; done; iptables -t filter -F $QCHAIN 2>/dev/null || true; iptables -t filter -X $QCHAIN 2>/dev/null || true"
      fi
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
    while iptables -t nat -D OUTPUT -j "\$IHOSTS" 2>/dev/null; do :; done
    iptables -t nat -A OUTPUT -j "\$IHOSTS"
$QUIC_START
  fi
}
stop(){
  [ -f /run/byedpi.pid ] && kill \$(cat /run/byedpi.pid) 2>/dev/null
  rm -f /run/byedpi.pid
  while iptables -t nat -D OUTPUT -j "\$IHOSTS" 2>/dev/null; do :; done
  iptables -t nat -F "\$IHOSTS" 2>/dev/null || true
  iptables -t nat -X "\$IHOSTS" 2>/dev/null || true
$QUIC_STOP
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
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -A OUTPUT -j $IHOSTS'
ExecStop=/bin/sh -c '\
while iptables -t nat -D OUTPUT -j $IHOSTS 2>/dev/null; do :; done; \
iptables -t nat -F $IHOSTS 2>/dev/null || true; \
iptables -t nat -X $IHOSTS 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
        run_root "install -m 644 /tmp/byedpi-redirect.$$ /etc/systemd/system/byedpi-redirect.service"
        rm -f /tmp/byedpi-redirect.$$
        run_root "systemctl daemon-reload"
        run_root "systemctl enable --now byedpi-redirect >/dev/null 2>&1 || true"
        [ "$BLOCK_QUIC" = "yes" ] && write_quic_unit
      fi
      log_ok "REDIRECT: ipset-правила (iptables)"
    fi
  fi
  # Юнит живёт только в transparent-режиме с включённой блокировкой.
  if { [ "$BLOCK_QUIC" != "yes" ] || [ "$METHOD" != "ipset" ]; } && \
     [ -f "/etc/systemd/system/$QUNIT.service" ]; then
    remove_quic_unit
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
  if [ -f "$CFG" ]; then
    m=$(current_mode)
    echo "режим:   $m"
    if [ "$m" = "transparent" ]; then
      if systemctl is-active --quiet byedpi-redirect 2>/dev/null; then
        echo "перехват: активен (byedpi-redirect)"
      else
        echo "перехват: [WARN] НЕ активен (byedpi-redirect) — трафик идёт мимо byedpi"
      fi
      if [ "$(quic_flag_from_conf 2>/dev/null || echo no)" = "yes" ]; then
        echo "QUIC:     UDP 443 блокируется ($QUNIT) — браузер пойдёт по TCP"
      else
        echo "QUIC:     не блокируется (UDP 443 идёт мимо byedpi)"
      fi
      echo "браузер:  напрямую; socks5 $PORT в transparent не работает (расширение выключить)"
    else
      echo "браузер:  через socks5 127.0.0.1:$PORT"
    fi
  fi
  exit 0
}

cmd_off(){
  echo "=== Отключение ByeDPI ==="
  systemctl --user disable --now byedpi.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/byedpi.service"

  for n in "byedpi" "byedpi-$UID_NUM" "byedpi-redirect" "byedpi-redirect-$UID_NUM" "byedpi-quic" "byedpi-quic-$UID_NUM"; do
    run_root "systemctl disable --now $n 2>/dev/null || true"
  done
  run_root "rm -f /etc/systemd/system/byedpi.service /etc/systemd/system/byedpi-$UID_NUM.service /etc/systemd/system/byedpi-redirect.service /etc/systemd/system/byedpi-redirect-$UID_NUM.service /etc/systemd/system/byedpi-quic.service /etc/systemd/system/byedpi-quic-$UID_NUM.service; systemctl daemon-reload 2>/dev/null || true"
  run_root "rm -f /etc/init.d/byedpi"

  # Снять ВСЕ ссылки на цепочки: за время работы юнит мог добавить их
  # несколько раз (каждый restart), а -D удаляет только одно вхождение.
  # Если оставить хоть одну, REDIRECT уведёт трафик в мёртвый порт.
  for c in $IHOSTS BYEDPI BYEDPI_HOSTS BYEDPI_$UID_NUM BYEDPI_HOSTS_$UID_NUM; do
    run_root "while iptables -t nat -D OUTPUT -j $c 2>/dev/null; do :; done; iptables -t nat -F $c 2>/dev/null || true; iptables -t nat -X $c 2>/dev/null || true"
  done
  for c in BYEDPI_QUIC BYEDPI_QUIC_$UID_NUM; do
    run_root "while iptables -t filter -D OUTPUT -j $c 2>/dev/null; do :; done; iptables -t filter -F $c 2>/dev/null || true; iptables -t filter -X $c 2>/dev/null || true"
  done

  run_root "rm -rf /etc/byedpi $LAUNCHER /usr/local/bin/byedpi"
  if [ -z "$KEEP_PACKAGE" ]; then
    run_root "apt-get remove -y byedpi >/dev/null 2>&1 || true"
    run_root "rm -f /usr/local/bin/ciadpi"
  fi
  rm -rf "$HOME/.config/byedpi"
  run_root "rm -f /etc/sysconfig/byedpi /etc/byedpi-hosts.txt /usr/local/bin/byedpi-hosts-update.sh /usr/local/bin/byedpi-hosts-update-$UID_NUM.sh"
  rm -f "$HOME/.config/byedpi.conf" "$HOME/.config/byedpi-hosts.txt"
  if [ -z "$KEEP_PACKAGE" ]; then
    echo "ByeDPI отключён. Конфиги, правила и пакет byedpi удалены."
  else
    echo "ByeDPI отключён. Конфиги и правила удалены, пакет byedpi оставлен (--keep-package)."
  fi
  exit 0
}

cmd_test(){
  [ -f "$HOSTS_FILE" ] || log_err "Нет hostlist: $HOSTS_FILE (сначала установите ByeDPI)."
  best=$(test_strategies "$HOSTS_FILE")
  wfile_root "$RULE_FILE" "$best"
  log_ok "Правило записано: $RULE_FILE"
  daemon_restart
}

# Проверка минимального набора доменов через работающий демон.
# Режим работы из конфига: transparent | socks
current_mode(){
  m=""
  if [ -f "$CFG" ]; then
    m=$(sed -n 's/^BYEDPI_MODE="\{0,1\}\([a-z]*\)"\{0,1\}.*/\1/p' "$CFG" | head -1)
  fi
  echo "${m:-socks}"
}

# Одна проба домена тем путём, которым реально ходит трафик:
# transparent — напрямую (перехватывает iptables), socks — через SOCKS5.
probe_via_mode(){ # домен -> http_code
  if [ "$(current_mode)" = "transparent" ]; then
    curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null
  else
    curl -k -sS -m 8 --socks5-hostname 127.0.0.1:"$PORT" -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null
  fi
}

# Проверка минимального набора доменов тем путём, которым ходит браузер.
cmd_check(){
  command -v curl >/dev/null 2>&1 || log_err "Для проверки нужен curl"
  mode=$(current_mode)
  echo "=== Проверка минимального набора доменов ==="
  echo "Режим: $mode"
  [ -f "$RULE_FILE" ] && echo "Правило: $(cat "$RULE_FILE")"
  if [ "$mode" = "transparent" ]; then
    echo "  Трафик TCP 80/443 перехватывает iptables (REDIRECT) — браузер ходит напрямую."
    if systemctl is-active --quiet byedpi-redirect 2>/dev/null; then
      echo "  Перехват: активен (byedpi-redirect)"
    else
      echo "  [WARN] Перехват не активен: systemctl status byedpi-redirect"
    fi
    sc=$(curl -k -sS -m 4 --socks5-hostname 127.0.0.1:"$PORT" -o /dev/null -w '%{http_code}' https://www.youtube.com/ 2>/dev/null)
    if [ "$sc" = "000" ]; then
      echo "  [WARN] Порт $PORT не принимает SOCKS5 — в transparent так и должно быть."
      echo "         Если браузер/ZeroOmega настроен на socks5 127.0.0.1:$PORT,"
      echo "         выключите расширение (или профиль 'прямое соединение'), иначе"
      echo "         сайты не откроются: SOCKS-запросы уходят в никуда."
    fi
  else
    echo "  Браузер должен ходить через SOCKS5 127.0.0.1:$PORT."
    echo "  Перехвата iptables нет: без прокси в браузере трафик идёт напрямую."
  fi
  echo
  for h in $TEST_PROBES; do
    # 3 попытки: DPI бывает статистическим и открывает не каждый поток
    i=0; code=""
    while [ $i -lt 3 ]; do
      code=$(probe_via_mode "$h")
      [ -n "$code" ] && [ "$code" != "000" ] && break
      i=$((i+1)); sleep 0.5
    done
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      if [ $i -gt 0 ]; then
        printf '  %-30s OK с %d-й попытки (%s) — фильтрация статистическая\n' "$h" "$((i+1))" "$code"
      else
        printf '  %-30s OK (%s)\n' "$h" "$code"
      fi
      continue
    fi
    inlist=no
    if [ -f "$HOSTS_FILE" ]; then
      re=$(printf '%s' "$h" | sed 's/\./\\./g')
      grep -qE "^[[:space:]]*${re}([[:space:]]*\$|[[:space:]]*#)" "$HOSTS_FILE" 2>/dev/null && inlist=yes
    fi
    if [ "$inlist" = yes ]; then
      printf '  %-30s FAIL 3/3 (домен есть в hosts) — desync не помогает\n' "$h"
    elif probe_direct "$h"; then
      printf '  %-30s FAIL (напрямую открывается, но домена нет в hosts)\n' "$h"
    else
      printf '  %-30s FAIL 3/3 — блок по IP или по отпечатку ClientHello (JA3)\n' "$h"
    fi
  done
  echo
  echo "Подсказка: если домен открывается напрямую (curl без прокси) — добавьте его"
  echo "в $HOSTS_FILE и перезапустите демон. Если FAIL 3/3 и напрямую, то"
  echo "блокируют либо по IP, либо по TLS-отпечатку (JA3) — desync/SNI не поможет."
  if [ "$mode" = "transparent" ]; then
    # QUIC (UDP 443) ByeDPI не перехватывает: REDIRECT только для TCP. Если
    # провайдер режет UDP 443, браузер висит на HTTP/3 до таймаута — это и есть
    # чёрный экран/крутилка YouTube при рабочем TCP. Проверяем фактически.
    qflag=$(quic_flag_from_conf 2>/dev/null || echo no)
    if [ "$qflag" = "yes" ]; then
      echo "QUIC:     UDP 443 блокируется ($QUNIT) — браузер идёт по TCP, ок"
    elif curl --version 2>/dev/null | grep -qi 'HTTP3'; then
      q_ok=0
      for i in 1 2 3; do
        c=$(curl -sS --http3-only -m 5 -o /dev/null -w '%{http_code}' https://www.youtube.com/ 2>/dev/null)
        [ -n "$c" ] && [ "$c" != "000" ] && q_ok=$((q_ok+1))
      done
      if [ "$q_ok" -eq 0 ]; then
        echo "QUIC:     [WARN] 0/3 — UDP 443 не проходит, а блокировка выключена."
        echo "          Браузер может висеть на HTTP/3 (чёрный экран YouTube)."
        echo "          Лечится: $0 --update --block-quic"
      else
        echo "QUIC:     $q_ok/3 проходит — блокировка не требуется"
      fi
    else
      echo "QUIC:     curl без поддержки HTTP/3 — проверить нельзя"
    fi
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# Главный запуск
# ---------------------------------------------------------------------------
case "$ACTION" in
  status) cmd_status ;;
  off)    cmd_off ;;
  test)   cmd_test ;;
  check)  cmd_check ;;
  update)
    install_packages
    write_hostlist
    write_rule
    resolve_quic_flag
    write_conf
    write_quic_flag
    write_launcher
    write_units
    daemon_restart
    if [ -n "$KEEP_FILES" ]; then
      log_ok "Launcher и юниты обновлены. Hostlist/rule оставлены как были (--keep-files)."
    else
      log_ok "Обновлено: hostlist, правило desync, launcher и юниты."
    fi
    echo "Проверить результат: $0 --check"
    ;;
  install)
    install_packages
    write_port
    write_hostlist
    write_rule
    resolve_quic_flag
    write_conf
    write_quic_flag
    write_launcher
    write_units
    daemon_restart
    echo "═══════════════════════════════════════════════════════════"
    echo "  ByeDPI (ALT Linux): scope=$SCOPE метод=$METHOD порт=$PORT"
    echo "═══════════════════════════════════════════════════════════"
    echo "Каталог:  $DIR"
    echo "Правка:   nano $DIR/hosts (или rule/port); перезапуск демона: $LAUNCHER"
    if [ "$METHOD" = "ipset" ]; then
      if [ "$BLOCK_QUIC" = "yes" ]; then
        echo "  QUIC (UDP 443): заблокирован ($QUNIT) — браузер идёт по TCP."
      else
        echo "  QUIC (UDP 443): не заблокирован — возможен чёрный экран YouTube."
      fi
    fi
    echo "Пересборка правила: $0 --test"
    echo "Обновить конфиги из свежего скрипта: $0 --update"
    echo "Не трогать существующие hosts/rule: добавьте --keep-files"
    [ "$SCOPE" = "user" ] && [ "$METHOD" = "extension" ] && echo "Автозапуск при входе включён. Для запуска без входа в сессию: su -s /bin/sh -c 'loginctl enable-linger $USER' root"
    ;;
esac