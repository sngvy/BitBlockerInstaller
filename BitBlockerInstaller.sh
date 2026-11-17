#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

log()  { echo -e "${B_CYAN}[*]${NC} $1"; }
ok()   { echo -e "${B_GREEN}[+]${NC} $1"; }
warn() { echo -e "${B_YELLOW}[!]${NC} $1"; }
err()  { echo -e "${B_RED}[-]${NC} $1"; }

# Показывает только процент/спиннер, полный лог выводится при ошибке
run_with_progress() {
    local label="$1"; shift
    local logfile spin i pct pid status
    logfile=$(mktemp)
    "$@" > "$logfile" 2>&1 &
    pid=$!
    spin='-\|/'
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        pct=$(grep -oE '\[[ 0-9]{1,3}%\]' "$logfile" | tail -1)
        i=$(( (i + 1) % 4 ))
        printf "\r${B_CYAN}[*]${NC} %s... %s %s" "$label" "${pct:-}" "${spin:$i:1}"
        sleep 0.5
    done
    wait "$pid"
    status=$?
    printf "\r\033[K"
    if [ "$status" -ne 0 ]; then
        err "$label — ошибка (код $status). Полный лог сборки:"
        echo "----------------------------------------"
        cat "$logfile"
        echo "----------------------------------------"
        rm -f "$logfile"
        return "$status"
    fi
    ok "$label — готово."
    rm -f "$logfile"
    return 0
}

if [ "$EUID" -ne 0 ]; then
    err "Запустите скрипт от имени root."
    exit 1
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn "Скрипт тестировался на Ubuntu/Debian."
fi

INSTALL_DIR="/opt/nDPId"
NDPID_REPO="https://github.com/utoni/nDPId.git"
# Чтобы собрать конкретную версию: NDPID_REF=<тег или коммит> bash bitblocker-install.sh
NDPID_REF="${NDPID_REF:-}"
NDPID_BIN="/usr/local/bin/bitblocker-ndpid"
LISTENER="/usr/local/bin/bitblocker-listener.py"
CTL="/usr/local/bin/bitblocker-ctl.sh"
OLD_DHT="/usr/local/bin/bitblocker-dht-block.sh"
CONF_DIR="/etc/bitblocker"
CONF="$CONF_DIR/bitblocker.conf"
STATE_DIR="/var/lib/bitblocker"
SOCK_PATH="/run/bitblocker/ndpid.sock"
LOG_FILE="/var/log/bitblocker.log"
UNIT_DIR="/etc/systemd/system"
NDPID_SERVICE="$UNIT_DIR/bitblocker-ndpid.service"
BACKUP_DIR="$CONF_DIR/backup/$(date +%Y%m%d-%H%M%S)"

NEW_SETS="bitblocker_src4 bitblocker_dst4 bitblocker_src6 bitblocker_dst6 bitblocker_dht4 bitblocker_dht6"
OLD_SETS="BITBLOCKER-SRC4 BITBLOCKER-DST4 BITBLOCKER-SRC6 BITBLOCKER-DST6 BITBLOCKER-FLOW4 BITBLOCKER-FLOW6"
ALL_UNITS="bitblocker-ipset.service bitblocker-listener.service bitblocker-ndpid.service bitblocker-dht-block.service bitblocker-dht-block.timer"

# ------------------------------------------------------------
# Функции очистки старой версии (используются и при миграции, и при удалении)
# ------------------------------------------------------------

# Прыжки и цепочки в таблице filter (очень старая цепочка BITBLOCKER и DHT-цепочка прошлой версии)
remove_legacy_filter_chains() {
    local cmd chain hook
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        for chain in BITBLOCKER BITBLOCKER-DHT; do
            $cmd -L "$chain" -n &>/dev/null || continue
            for hook in INPUT OUTPUT FORWARD; do
                while $cmd -D "$hook" -j "$chain" 2>/dev/null; do :; done
            done
            $cmd -F "$chain" 2>/dev/null
            $cmd -X "$chain" 2>/dev/null
        done
    done
}

legacy_filter_chains_present() {
    local cmd chain
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        for chain in BITBLOCKER BITBLOCKER-DHT; do
            $cmd -L "$chain" -n &>/dev/null && return 0
        done
    done
    return 1
}

# В user.rules комментарий хранится в hex-виде, поэтому поиск по тексту его не находит.
# Удаляем целиком блоки (строка tuple и правила до пустой строки).
remove_legacy_ufw_dht() {
    local plain="BitBlocker-DHT" hex f before after changed=0
    hex=$(printf '%s' "$plain" | od -An -tx1 | tr -d ' \n')
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        [ -f "$f" ] || continue
        before=$(grep -c '^### tuple ###' "$f")
        awk -v plain="$plain" -v hex="$hex" '
            /^### tuple ###/ { skip = (index(tolower($0), hex) || index($0, plain)) ? 1 : 0 }
            /^$/ { if (skip) { skip = 0; next } }
            { if (!skip) print }
        ' "$f" > "$f.new" && cat "$f.new" > "$f"
        rm -f "$f.new"
        after=$(grep -c '^### tuple ###' "$f")
        if [ "$before" != "$after" ]; then
            changed=1
            warn "$f: удалено старых правил: $((before - after))"
        fi
    done
    if [ "$changed" -eq 1 ] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw reload >/dev/null 2>&1
    fi
}

legacy_ufw_dht_present() {
    local hex f
    hex=$(printf '%s' "BitBlocker-DHT" | od -An -tx1 | tr -d ' \n')
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        [ -f "$f" ] || continue
        grep '^### tuple ###' "$f" | tr 'A-F' 'a-f' | grep -q "$hex" && return 0
        grep -q 'BitBlocker-DHT' "$f" && return 0
    done
    return 1
}

# Файл /etc/iptables/ipsets (пакет ipset-persistent) может хранить записи старых наборов
clean_ipsets_file() {  # шаблон имени набора
    local f=/etc/iptables/ipsets
    [ -f "$f" ] || return 0
    grep -qE "^(create|add) ($1) " "$f" || return 0
    sed -i -E "/^(create|add) ($1) /d" "$f"
    warn "Из $f удалены записи наборов: $1"
}

destroy_sets() {  # список имён
    local s
    for s in $1; do
        ipset list -n 2>/dev/null | grep -qx "$s" && ipset destroy "$s" 2>/dev/null
    done
}

remove_raw_chain() {
    local cmd hook
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        for hook in PREROUTING OUTPUT; do
            while $cmd -t raw -D "$hook" -j BITBLOCKER 2>/dev/null; do :; done
        done
        $cmd -t raw -F BITBLOCKER 2>/dev/null
        $cmd -t raw -X BITBLOCKER 2>/dev/null
    done
}

save_iptables_files() {
    [ -d /etc/iptables ] || return 0
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
}

uninstall_bitblocker() {
    echo -e "${B_CYAN}${BOLD}Удаление BitBlocker${NC}"
    echo

    local unit had_refs=0
    for unit in bitblocker-ndpid.service bitblocker-listener.service bitblocker-dht-block.timer \
                bitblocker-dht-block.service bitblocker-ipset.service; do
        if [ -f "$UNIT_DIR/$unit" ]; then
            systemctl stop "$unit" 2>/dev/null
            systemctl disable "$unit" 2>/dev/null
            rm -f "$UNIT_DIR/$unit"
            ok "Служба $unit остановлена и удалена."
        fi
    done
    systemctl daemon-reload

    grep -qs 'BITBLOCKER' /etc/iptables/rules.v4 /etc/iptables/rules.v6 && had_refs=1

    remove_raw_chain
    ok "Цепочка BITBLOCKER (raw) удалена."
    remove_legacy_filter_chains
    remove_legacy_ufw_dht

    destroy_sets "$NEW_SETS $OLD_SETS"
    clean_ipsets_file 'bitblocker_[a-z]+[46]|BITBLOCKER-(SRC|DST|FLOW)[46]'
    ok "Наборы ipset BitBlocker удалены."

    # Если правила были сохранены в rules.v4/v6, сохраняем состояние без них,
    # иначе после ребута iptables-restore упадёт на отсутствующих наборах
    [ "$had_refs" -eq 1 ] && save_iptables_files

    rm -f "$NDPID_BIN" "$LISTENER" "$CTL" "$OLD_DHT"
    ok "Бинарник и скрипты BitBlocker удалены."
    rm -rf "$INSTALL_DIR" /run/bitblocker "$CONF_DIR" "$STATE_DIR" /run/bitblocker-ctl.lock
    ok "Каталоги сборки, сокета, конфига и состояния удалены."
    rm -f /etc/logrotate.d/bitblocker
    ok "Конфиг logrotate удалён."
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
        ok "Лог $LOG_FILE удалён."
    fi

    echo
    echo -e "${B_GREEN}${BOLD}BitBlocker полностью удалён.${NC}"
    warn "Пакеты (git, cmake, iptables-persistent, ufw, ipset и т.п.) не удалялись — они могут использоваться системой."
}

echo -e "${B_CYAN}${BOLD}BitBlocker${NC}"
echo
echo -e "1) Установить"
echo -e "2) Удалить"
read -r -p $'\033[1;33mВаш выбор [1-2]: \033[0m' ACTION_CHOICE

case "$ACTION_CHOICE" in
    2)
        uninstall_bitblocker
        exit 0
        ;;
    1) ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac
echo

echo -e "${BOLD}Конфигурация BitBlocker${NC}"
echo
echo -e "BitBlocker работает на базе ${BOLD}nDPId${NC} (userspace DPI, без кастомного ядерного"
echo -e "модуля): nDPId захватывает трафик на интерфейсе и классифицирует потоки через nDPI,"
echo -e "а слушатель BitBlocker разбирает его JSON-события и точечно блокирует обнаруженные"
echo -e "BitTorrent-потоки через ipset и iptables (таблица raw) с автоматическим"
echo -e "удалением записей по TTL. Известные DHT-бутстрап ноды блокируются отдельным набором ipset"
echo -e "(список IP обновляется раз в 30 минут)."
echo

# ------------------------------------------------------------
# Определяем, есть ли предыдущая установка и какие у неё настройки
# ------------------------------------------------------------
PREV_FW_MODE=""
PREV_DHT_PORT_MODE=""
PREV_PORTS_INPUT=""
PREV_IFACE=""
LEGACY=0

if [ -f "$CONF" ]; then
    PREV_FW_MODE=$( . "$CONF" 2>/dev/null; printf '%s' "$FW_MODE" )
    PREV_DHT_PORT_MODE=$( . "$CONF" 2>/dev/null; printf '%s' "$DHT_PORT_MODE" )
    PREV_PORTS_INPUT=$( . "$CONF" 2>/dev/null; printf '%s' "$PORTS_INPUT" )
    PREV_IFACE=$( . "$CONF" 2>/dev/null; printf '%s' "$IFACE" )
    warn "Найдена установка BitBlocker с наборами bitblocker_* (режим: ${PREV_FW_MODE:-неизвестен}). Будет обновление."
elif [ -f "$OLD_DHT" ] || [ -f "$NDPID_SERVICE" ] || [ -f "$LISTENER" ]; then
    LEGACY=1
    if [ -f "$OLD_DHT" ]; then
        PREV_FW_MODE=$(grep -oP '(?<=^FW_MODE=")[^"]*' "$OLD_DHT" 2>/dev/null)
        PREV_DHT_PORT_MODE=$(grep -oP '(?<=^DHT_PORT_MODE=")[^"]*' "$OLD_DHT" 2>/dev/null)
        PREV_PORTS_INPUT=$(grep -oP '(?<=^PORTS_INPUT=")[^"]*' "$OLD_DHT" 2>/dev/null)
    fi
    warn "Найдена старая установка BitBlocker (наборы BITBLOCKER-*, режим: ${PREV_FW_MODE:-неизвестен}). Выполню миграцию."
fi
if [ -z "$PREV_IFACE" ] && [ -f "$NDPID_SERVICE" ]; then
    PREV_IFACE=$(grep -oP '(?<=-i )\S+' "$NDPID_SERVICE" 2>/dev/null | head -1)
fi
[ -n "$PREV_FW_MODE" ] && echo -e "  Текущий firewall:      $PREV_FW_MODE"
[ -n "$PREV_DHT_PORT_MODE" ] && echo -e "  Текущий режим портов:  $PREV_DHT_PORT_MODE"
[ -n "$PREV_PORTS_INPUT" ] && echo -e "  Текущие порты:         $PREV_PORTS_INPUT"
[ -n "$PREV_IFACE" ] && echo -e "  Текущий интерфейс:     $PREV_IFACE"
if [ -n "$PREV_FW_MODE" ]; then
    warn "При переустановке можно оставить значения без изменений (Enter) или задать новые."
fi
echo

echo -e "${B_CYAN}Какой firewall используется на сервере для прочих правил?${NC}"
echo -e "1) iptables (прямые правила + iptables-persistent)"
echo -e "2) ufw"
if [ -n "$PREV_FW_MODE" ]; then
    read -r -p $'\033[1;33m'"Ваш выбор [1-2] (Enter — оставить текущий: $PREV_FW_MODE): "$'\033[0m' FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        case "$PREV_FW_MODE" in
            iptables) FW_CHOICE=1 ;;
            ufw) FW_CHOICE=2 ;;
        esac
    fi
else
    read -r -p $'\033[1;33mВаш выбор [1-2]: \033[0m' FW_CHOICE
fi

case "$FW_CHOICE" in
    1) FW_MODE="iptables" ;;
    2) FW_MODE="ufw" ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac

echo
echo -e "${B_CYAN}Выберите, какой трафик nDPId должен анализировать:${NC}"
echo -e "1) По конкретным портам — nDPId захватывает только пакеты на заданных портах/диапазоне"
echo -e "2) По всем портам — nDPId анализирует весь трафик на интерфейсе"
echo -e "3) По всем портам, кроме указанных"
if [ -n "$PREV_DHT_PORT_MODE" ]; then
    read -r -p $'\033[1;33m'"Ваш выбор [1-3] (Enter — оставить текущий: $PREV_DHT_PORT_MODE): "$'\033[0m' BLOCK_CHOICE
    if [ -z "$BLOCK_CHOICE" ]; then
        case "$PREV_DHT_PORT_MODE" in
            only) BLOCK_CHOICE=1 ;;
            all) BLOCK_CHOICE=2 ;;
            except) BLOCK_CHOICE=3 ;;
        esac
    fi
else
    read -r -p $'\033[1;33mВаш выбор [1-3]: \033[0m' BLOCK_CHOICE
fi

# Фильтр на уровне захвата пакетов (libpcap), не самой DPI-проверки
bpf_clauses() {
    local input clause list="" t
    local -a tokens
    input=$(echo "$1" | tr -d ' ')
    IFS=',' read -ra tokens <<< "$input"
    for t in "${tokens[@]}"; do
        [ -z "$t" ] && continue
        if [[ "$t" == *-* ]]; then
            clause="portrange $t"
        else
            clause="port $t"
        fi
        if [ -z "$list" ]; then
            list="$clause"
        else
            list="$list or $clause"
        fi
    done
    echo "$list"
}

# Проверка списка портов: числа 1-65535, диапазоны по возрастанию, не больше 15 позиций
# (лимит multiport в iptables: диапазон занимает две позиции).
validate_ports() {
    local in t lo hi slots=0
    local -a toks
    in=$(echo "$1" | tr -d ' ')
    [[ "$in" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    IFS=',' read -ra toks <<< "$in"
    for t in "${toks[@]}"; do
        if [[ "$t" == *-* ]]; then
            lo=${t%-*}; hi=${t#*-}; slots=$((slots + 2))
        else
            lo=$t; hi=$t; slots=$((slots + 1))
        fi
        (( 10#$lo >= 1 && 10#$hi <= 65535 && 10#$lo <= 10#$hi )) || return 1
    done
    [ "$slots" -le 15 ] || return 2
    PORTS_NORM="$in"
    return 0
}

ask_ports() {  # приглашение, значение по умолчанию
    local reply
    if [ -n "$PREV_PORTS_INPUT" ]; then
        read -r -p $'\033[1;33m'"$1 (Enter — оставить текущие: $PREV_PORTS_INPUT): "$'\033[0m' reply
        reply="${reply:-$PREV_PORTS_INPUT}"
    elif [ -n "$2" ]; then
        read -r -p $'\033[1;33m'"$1 [по умолчанию $2]: "$'\033[0m' reply
        reply="${reply:-$2}"
    else
        read -r -p $'\033[1;33m'"$1: "$'\033[0m' reply
    fi
    if [ -z "$reply" ]; then
        err "Нужно указать хотя бы один порт."
        exit 1
    fi
    validate_ports "$reply"
    case $? in
        0) ;;
        2) err "Слишком много портов: в iptables допускается не больше 15 позиций (диапазон считается за две)."; exit 1 ;;
        *) err "Неверный формат портов: $reply"; exit 1 ;;
    esac
    PORTS_INPUT="$PORTS_NORM"
}

BPF_FILTER=""
DHT_PORT_MODE="all"
DHT_PORTS=""
PORTS_INPUT=""
case "$BLOCK_CHOICE" in
    1)
        echo
        echo -e "${B_CYAN}Укажите порты. Поддерживаются:${NC}"
        echo -e "  - диапазон:        6881-6889"
        echo -e "  - список через запятую: 6881,6969,51413"
        echo -e "  - смешанный вариант:    6881-6889,51413,6969"
        ask_ports "Порты" "6881-6889"
        BPF_FILTER="(tcp or udp) and ($(bpf_clauses "$PORTS_INPUT"))"
        DHT_PORT_MODE="only"
        DHT_PORTS=$(echo "$PORTS_INPUT" | sed 's/-/:/g')
        ;;
    2)
        BPF_FILTER=""
        DHT_PORT_MODE="all"
        ;;
    3)
        echo
        echo -e "${B_CYAN}Укажите порты для исключения из анализа:${NC}"
        echo -e "  - диапазон:        6881-6889"
        echo -e "  - список через запятую: 6881,6969,51413"
        echo -e "  - смешанный вариант:    6881-6889,51413,6969"
        ask_ports "Порты для исключения" ""
        BPF_FILTER="not ($(bpf_clauses "$PORTS_INPUT"))"
        DHT_PORT_MODE="except"
        DHT_PORTS=$(echo "$PORTS_INPUT" | sed 's/-/:/g')
        ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac

echo
DETECTED_IFACE=$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')
SUGGESTED_IFACE="${PREV_IFACE:-$DETECTED_IFACE}"
if [ -n "$SUGGESTED_IFACE" ]; then
    read -r -p $'\033[1;33m'"Интерфейс для анализа трафика (Enter — $SUGGESTED_IFACE): "$'\033[0m' IFACE_INPUT
    IFACE="${IFACE_INPUT:-$SUGGESTED_IFACE}"
else
    err "Не удалось автоматически определить интерфейс с маршрутом по умолчанию."
    read -r -p $'\033[1;33mУкажите интерфейс вручную (например eth0): \033[0m' IFACE
    if [ -z "$IFACE" ]; then
        err "Интерфейс не указан. Выход."
        exit 1
    fi
fi
if [[ ! "$IFACE" =~ ^[A-Za-z0-9_.:@-]+$ ]]; then
    err "Недопустимое имя интерфейса: $IFACE"
    exit 1
fi
ok "Интерфейс для анализа трафика: ${IFACE}"

# ------------------------------------------------------------
# Пакеты и сборка nDPId. Файрвол на этом этапе не трогаем.
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

log "Обновление списка пакетов и установка зависимостей..."
apt-get update -qq

BASE_PKGS="build-essential git cmake gettext flex bison libtool autoconf automake pkg-config libpcap-dev libjson-c-dev libnuma-dev libpcre2-dev libmaxminddb-dev librrd-dev python3 ipset util-linux logrotate"

if [ "$FW_MODE" = "ufw" ]; then
    apt-get install -y -qq ufw $BASE_PKGS
else
    mkdir -p /etc/iptables
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get install -y -qq iptables iptables-persistent $BASE_PKGS
fi

if ! command -v ipset >/dev/null || ! command -v iptables-restore >/dev/null || ! command -v flock >/dev/null; then
    err "Не удалось установить ipset, iptables или util-linux. Выход, старые правила не тронуты."
    exit 1
fi

SKIP_BUILD=0
if [ -x "$NDPID_BIN" ]; then
    NDPID_CHECK=$("$NDPID_BIN" -h 2>&1)
    if [ -n "$NDPID_CHECK" ] && ! echo "$NDPID_CHECK" | grep -qi "error while loading shared libraries"; then
        SKIP_BUILD=1
        ok "Найден уже собранный и рабочий бинарник nDPId: ${NDPID_BIN} — сборка пропущена."
    else
        warn "Бинарник ${NDPID_BIN} найден, но не запускается (нет вывода или ошибка загрузки библиотек). Пересобираю."
    fi
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
    log "Клонирование nDPId (включая submodule libnDPI)..."
    rm -rf "$INSTALL_DIR"
    if [ -n "$NDPID_REF" ]; then
        run_with_progress "Клонирование nDPId ($NDPID_REF)" git clone --recursive --branch "$NDPID_REF" "$NDPID_REPO" "$INSTALL_DIR" || exit 1
    else
        run_with_progress "Клонирование nDPId" git clone --recursive "$NDPID_REPO" "$INSTALL_DIR" || exit 1
    fi
    BUILT_REF=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)

    cd "$INSTALL_DIR" || exit 1
    mkdir -p build
    cd build || exit 1

    run_with_progress "Настройка cmake (-DBUILD_NDPI=ON)" cmake -DBUILD_NDPI=ON -DBUILD_EXAMPLES=OFF .. || exit 1
    run_with_progress "Сборка nDPId" make -j"$(nproc)" || exit 1

    BUILT_BIN=$(find . -maxdepth 2 -type f -name 'nDPId' -perm -u+x | head -n1)
    if [ -z "$BUILT_BIN" ]; then
        err "Не нашёл собранный бинарник nDPId после сборки."
        exit 1
    fi
    cp "$BUILT_BIN" "$NDPID_BIN"
    chmod +x "$NDPID_BIN"
    ok "nDPId собран и установлен в ${NDPID_BIN} (коммит ${BUILT_REF:-неизвестен}; зафиксировать версию: NDPID_REF=${BUILT_REF:-<коммит>})."

    cd /
    rm -rf "$INSTALL_DIR"
    ok "Каталог сборки $INSTALL_DIR удалён — бинарник уже скопирован в $NDPID_BIN."
fi

BPF_ARG=""
if [ -n "$BPF_FILTER" ]; then
    HELP_TEXT=$("$NDPID_BIN" -h 2>&1; "$NDPID_BIN" --help 2>&1)
    BPF_FLAG=$(echo "$HELP_TEXT" | grep -iE '^\s*-[A-Za-z]([^A-Za-z].*)?bpf' | grep -oE '^\s*-[A-Za-z]' | tr -d ' ' | head -n1)
    if [ -z "$BPF_FLAG" ]; then
        warn "Не нашёл в справке nDPId флаг для BPF-фильтра — ограничение по портам применить не удастся."
        warn "Проверьте вручную: $NDPID_BIN -h | grep -i bpf"
        warn "nDPId будет анализировать весь трафик на интерфейсе (как в режиме «по всем портам»)."
    else
        ok "Найден флаг BPF-фильтра в справке nDPId: $BPF_FLAG"
        BPF_ARG="$BPF_FLAG \"$BPF_FILTER\""
    fi
fi

# ------------------------------------------------------------
# Резервные копии всего, что будем менять
# ------------------------------------------------------------
install -d -m 700 "$CONF_DIR" "$STATE_DIR" "$BACKUP_DIR"

backup_file() {
    [ -e "$1" ] || return 0
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

for f in "$OLD_DHT" "$LISTENER" "$CTL" "$CONF" "$NDPID_SERVICE" \
         $(for u in $ALL_UNITS; do echo "$UNIT_DIR/$u"; done) \
         /etc/ufw/user.rules /etc/ufw/user6.rules \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/ipsets; do
    backup_file "$f"
done
for s in $OLD_SETS $NEW_SETS; do
    ipset list -n 2>/dev/null | grep -qx "$s" && ipset save "$s" > "$BACKUP_DIR/ipset-$s.save" 2>/dev/null
done
command -v iptables-save >/dev/null && iptables-save > "$BACKUP_DIR/iptables-save.v4" 2>/dev/null
command -v ip6tables-save >/dev/null && ip6tables-save > "$BACKUP_DIR/ip6tables-save.v6" 2>/dev/null
warn "Резервные копии на время установки: $BACKUP_DIR (удалятся после успешной проверки)"

# ------------------------------------------------------------
# Конфиг
# ------------------------------------------------------------
{
    echo "# Конфигурация BitBlocker."
    echo "# FW_MODE: iptables (правила сохраняются в rules.v4/v6) или ufw."
    echo "# DHT_PORT_MODE: all | only | except. DHT_PORTS: порты в формате iptables multiport."
    printf "FW_MODE='%s'\n" "$FW_MODE"
    printf "DHT_PORT_MODE='%s'\n" "$DHT_PORT_MODE"
    printf "DHT_PORTS='%s'\n" "$DHT_PORTS"
    printf "PORTS_INPUT='%s'\n" "$PORTS_INPUT"
    printf "IFACE='%s'\n" "$IFACE"
} > "$CONF.new"
chmod 600 "$CONF.new"
mv "$CONF.new" "$CONF"

# --- Ротация логов: храним только последние 7 дней ---
cat << LOGROTATE_EOF > /etc/logrotate.d/bitblocker
$LOG_FILE {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE_EOF

# ------------------------------------------------------------
# Управляющий скрипт: наборы ipset, цепочка в таблице raw, список DHT.
# Подкоманды: update (по умолчанию) | restore | ensure-rules | save-rules
# ------------------------------------------------------------
cat << 'CTL_EOF' > "$CTL"
#!/bin/bash

CONF="/etc/bitblocker/bitblocker.conf"
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi

FW_MODE="${FW_MODE:-iptables}"
DHT_PORT_MODE="${DHT_PORT_MODE:-all}"
DHT_PORTS="${DHT_PORTS:-}"

STATE_DIR="/var/lib/bitblocker"
SAVE_FILE="$STATE_DIR/dht.save"
LOG_FILE="/var/log/bitblocker.log"
CHAIN="BITBLOCKER"
SRC4="bitblocker_src4"; DST4="bitblocker_dst4"; DHT4="bitblocker_dht4"
SRC6="bitblocker_src6"; DST6="bitblocker_dst6"; DHT6="bitblocker_dht6"
FLOW_TTL=86400
FLOW_MAXE=262144

# Каждая нода — свой порт (не все совпадают: dht.libtorrent.org слушает не 6881)
DHT_HOSTS=(
    "router.bittorrent.com:6881"
    "router.utorrent.com:6881"
    "dht.transmissionbt.com:6881"
    "dht.aelitis.com:6881"
    "dht.libtorrent.org:25401"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

mkdir -p "$STATE_DIR"
if ! command -v ipset >/dev/null; then
    log "[ERROR] ipset не найден"
    exit 1
fi

exec 9>/run/bitblocker-ctl.lock
if ! flock -w 120 9; then
    log "[ERROR] Не удалось получить блокировку, другой экземпляр занят"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

create_sets() {
    ipset create -exist "$SRC4" hash:ip,port family inet  timeout "$FLOW_TTL" maxelem "$FLOW_MAXE"
    ipset create -exist "$DST4" hash:ip,port family inet  timeout "$FLOW_TTL" maxelem "$FLOW_MAXE"
    ipset create -exist "$SRC6" hash:ip,port family inet6 timeout "$FLOW_TTL" maxelem "$FLOW_MAXE"
    ipset create -exist "$DST6" hash:ip,port family inet6 timeout "$FLOW_TTL" maxelem "$FLOW_MAXE"
    ipset create -exist "$DHT4" hash:ip,port family inet  maxelem 1024
    ipset create -exist "$DHT6" hash:ip,port family inet6 maxelem 1024
}

restore_sets() {
    if [ -s "$SAVE_FILE" ]; then
        ipset restore -exist < "$SAVE_FILE" || log "[WARN] Не удалось полностью восстановить $SAVE_FILE"
    fi
}

save_dht() {
    { ipset save "$DHT4"; ipset save "$DHT6"; } > "$SAVE_FILE.tmp" && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
    chmod 600 "$SAVE_FILE"
}

set_count() {
    ipset list -t "$1" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}'
}

# Атомарная загрузка: наполняем временный набор и меняем местами с рабочим
load_set() {  # набор, семейство, файл
    local set="$1" fam="$2" file="$3" tmp="${1}_tmp"
    ipset destroy "$tmp" 2>/dev/null
    ipset create "$tmp" hash:ip,port family "$fam" maxelem 1024 || return 1
    if [ -s "$file" ]; then
        if ! sed "s/^/add $tmp /" "$file" | ipset restore -exist 2>/dev/null; then
            ipset destroy "$tmp" 2>/dev/null
            return 1
        fi
    fi
    if ! ipset swap "$tmp" "$set"; then
        ipset destroy "$tmp" 2>/dev/null
        return 1
    fi
    ipset destroy "$tmp"
}

# Разрешаем имена бутстрап-нод. Частные и служебные адреса отбрасываем.
# Формат записей набора: "адрес,udp:порт".
resolve_hosts() {  # файл IPv4, файл IPv6
    local entry host port ips
    : > "$1"; : > "$2"
    for entry in "${DHT_HOSTS[@]}"; do
        host="${entry%%:*}"
        port="${entry##*:}"
        ips=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
        if [ -z "$ips" ]; then
            log "[WARN] Не удалось разрешить $host"
            continue
        fi
        printf '%s\n' "$ips" | awk -v port="$port" -v f4="$1" -v f6="$2" '
        {
            s = tolower($0)
            if (s ~ /^::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) sub(/^::ffff:/, "", s)
            if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                n = split(s, a, "."); bad = 0
                for (k = 1; k <= n; k++) if (a[k] + 0 > 255) bad = 1
                if (bad) next
                if (a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224) next
                if (a[1] == 169 && a[2] == 254) next
                if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) next
                if (a[1] == 192 && a[2] == 168) next
                if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) next
                print s ",udp:" port >> f4
            } else if (s ~ /^[0-9a-f:]+$/ && s ~ /:.*:/) {
                if (s == "::" || s == "::1") next
                if (s ~ /^fe[89ab][0-9a-f]:/ || s ~ /^f[cd][0-9a-f][0-9a-f]:/) next
                print s ",udp:" port >> f6
            }
        }'
    done
    sort -u -o "$1" "$1"
    sort -u -o "$2" "$2"
}

# Содержимое цепочки BITBLOCKER для iptables-restore (семейство 4 или 6).
# Порядок: потоки BitTorrent (прямое и ответное направление), затем DHT-бутстрапы.
build_rules() {
    local src dst dht
    if [ "$1" = "6" ]; then src=$SRC6; dst=$DST6; dht=$DHT6; else src=$SRC4; dst=$DST4; dht=$DHT4; fi
    echo "*raw"
    echo ":$CHAIN - [0:0]"
    echo "-F $CHAIN"
    echo "-A $CHAIN -m set --match-set $src src,src -m set --match-set $dst dst,dst -j DROP"
    echo "-A $CHAIN -m set --match-set $dst src,src -m set --match-set $src dst,dst -j DROP"
    case "$DHT_PORT_MODE" in
        except)
            echo "-A $CHAIN -p udp -m multiport --sports $DHT_PORTS -j RETURN"
            echo "-A $CHAIN -p udp -m set --match-set $dht dst,dst -j DROP"
            ;;
        only)
            echo "-A $CHAIN -p udp -m multiport --sports $DHT_PORTS -m set --match-set $dht dst,dst -j DROP"
            ;;
        *)
            echo "-A $CHAIN -p udp -m set --match-set $dht dst,dst -j DROP"
            ;;
    esac
    echo "COMMIT"
}

ensure_jump() {  # iptables|ip6tables, хук
    local cmd="$1" hook="$2" n
    n=$($cmd -t raw -S "$hook" 2>/dev/null | grep -cx -- "-A $hook -j $CHAIN")
    if [ "$n" -ne 1 ]; then
        while $cmd -t raw -D "$hook" -j "$CHAIN" 2>/dev/null; do :; done
        $cmd -t raw -I "$hook" 1 -j "$CHAIN" || log "[ERROR] ($cmd) Не удалось добавить переход в $hook"
    fi
}

# Цепочка пересобирается целиком одной транзакцией, поэтому защита не пропадает
# ни на мгновение и дублей не бывает.
ensure_rules() {
    local fam cmd rc=0
    for fam in 4 6; do
        if [ "$fam" = "4" ]; then cmd=iptables; else cmd=ip6tables; fi
        command -v "${cmd}-restore" >/dev/null || continue
        if ! build_rules "$fam" | "${cmd}-restore" --noflush; then
            log "[ERROR] ($cmd) Не удалось применить цепочку $CHAIN"
            rc=1
            continue
        fi
        ensure_jump "$cmd" PREROUTING
        ensure_jump "$cmd" OUTPUT
    done
    return $rc
}

persist() {
    [ "$FW_MODE" = "iptables" ] || return 0
    [ -d /etc/iptables ] || return 0
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
}

cmd_update() {
    local v4="$TMP_DIR/v4" v6="$TMP_DIR/v6" n4 n6 old rc=0
    create_sets
    resolve_hosts "$v4" "$v6"
    n4=$(wc -l < "$v4"); n6=$(wc -l < "$v6")
    old=$(( $(set_count "$DHT4") + $(set_count "$DHT6") ))

    if [ $((n4 + n6)) -eq 0 ]; then
        log "[ERROR] Ни один DHT-хост не разрешился, наборы не изменены"
        rc=1
    elif [ "$old" -ge 4 ] && [ $(( (n4 + n6) * 2 )) -lt "$old" ]; then
        log "[ERROR] Список DHT сократился с $old до $((n4 + n6)) адресов, похоже на сбой DNS. Наборы не изменены"
        rc=1
    elif load_set "$DHT4" inet "$v4" && load_set "$DHT6" inet6 "$v6"; then
        save_dht
        log "[SUCCESS] DHT-бутстрап: IPv4 $n4, IPv6 $n6 (режим портов: $DHT_PORT_MODE, firewall: $FW_MODE)"
    else
        log "[ERROR] Не удалось загрузить наборы DHT"
        rc=1
    fi

    # Правила проверяем при любом исходе: потоки BitTorrent блокируются независимо от DHT
    ensure_rules || rc=1
    return $rc
}

case "${1:-update}" in
    update)       cmd_update; rc=$?; persist; exit $rc ;;
    restore)      create_sets; restore_sets ;;
    ensure-rules) create_sets; ensure_rules; rc=$?; persist; exit $rc ;;
    save-rules)   persist ;;
    *) echo "Использование: $0 [update|restore|ensure-rules|save-rules]"; exit 1 ;;
esac
CTL_EOF
chmod 700 "$CTL"

# ------------------------------------------------------------
# Слушатель событий nDPId
# ------------------------------------------------------------
log "Установка слушателя BitBlocker: $LISTENER"

cat << 'PYEOF' > "$LISTENER"
#!/usr/bin/env python3
"""Слушает JSON-события nDPId и блокирует обнаруженные BitTorrent-потоки."""

import ipaddress
import json
import os
import socket
import subprocess
import sys
import threading
import time

SOCK_PATH = os.environ.get("BITBLOCKER_SOCK", "/run/bitblocker/ndpid.sock")
LOG_FILE = os.environ.get("BITBLOCKER_LOG", "/var/log/bitblocker.log")
CTL = os.environ.get("BITBLOCKER_CTL", "/usr/local/bin/bitblocker-ctl.sh")

# Решение по порту ("guessed") ненадёжно: блокируем только по содержимому потока
DETECT_EVENTS = {"detected", "detection-update"}

IPSET_TIMEOUT = 86400
SETS = {4: ("bitblocker_src4", "bitblocker_dst4"), 6: ("bitblocker_src6", "bitblocker_dst6")}

# Повторные события одного потока игнорируем 10 минут, дальше обновляем TTL записи.
# Словарь ограничен по размеру, поэтому память не растёт.
SEEN_TTL = 600
SEEN_MAX = 100000
_seen = {}
_seen_lock = threading.Lock()
_last_purge = 0.0


def log(tag, msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{tag}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def purge_seen(now):
    global _last_purge
    if now - _last_purge < 60 and len(_seen) < SEEN_MAX:
        return
    _last_purge = now
    for k in [k for k, t in _seen.items() if t <= now]:
        del _seen[k]
    if len(_seen) >= SEEN_MAX:
        _seen.clear()


def ensure_rules():
    """Наборы и цепочку создаёт управляющий скрипт, чтобы логика жила в одном месте."""
    try:
        r = subprocess.run([CTL, "ensure-rules"], capture_output=True, timeout=180)
        if r.returncode != 0:
            log("ERROR", f"ensure-rules завершился с кодом {r.returncode}: "
                         f"{r.stdout.decode(errors='replace')[-300:]}")
    except (OSError, subprocess.TimeoutExpired) as e:
        log("ERROR", f"Не удалось выполнить ensure-rules: {e}")


def parse_flow(event):
    """Возвращает (версия, src, dst) в формате ipset или None, если событие некорректно."""
    try:
        src = ipaddress.ip_address(event.get("src_ip"))
        dst = ipaddress.ip_address(event.get("dst_ip"))
        sport = int(event.get("src_port"))
        dport = int(event.get("dst_port"))
    except (ValueError, TypeError):
        return None
    l4 = event.get("l4_proto")
    if l4 not in ("tcp", "udp") or src.version != dst.version:
        return None
    if not (1 <= sport <= 65535 and 1 <= dport <= 65535):
        return None
    return src.version, f"{src},{l4}:{sport}", f"{dst},{l4}:{dport}"


def block_flow(event):
    flow = parse_flow(event)
    if flow is None:
        return
    ver, src_elem, dst_elem = flow

    now = time.time()
    with _seen_lock:
        purge_seen(now)
        key = (src_elem, dst_elem)
        if _seen.get(key, 0) > now:
            return
        _seen[key] = now + SEEN_TTL

    src_set, dst_set = SETS[ver]
    data = (f"add {src_set} {src_elem} timeout {IPSET_TIMEOUT}\n"
            f"add {dst_set} {dst_elem} timeout {IPSET_TIMEOUT}\n")
    try:
        r = subprocess.run(["ipset", "restore", "-exist"], input=data.encode(),
                           capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("ERROR", f"ipset недоступен: {e}")
        return
    proto_name = (event.get("ndpi") or {}).get("proto", "BitTorrent")
    if r.returncode != 0:
        log("ERROR", f"Не удалось заблокировать поток {src_elem} -> {dst_elem}: "
                     f"{r.stderr.decode(errors='replace').strip()[-200:]}")
        return
    log("SUCCESS", f"Заблокирован поток {proto_name}: {src_elem} -> {dst_elem}")


def handle_event(raw_bytes):
    try:
        event = json.loads(raw_bytes)
    except json.JSONDecodeError:
        return
    if not isinstance(event, dict):
        return
    if event.get("flow_event_name") not in DETECT_EVENTS:
        return
    ndpi = event.get("ndpi")
    if not isinstance(ndpi, dict):
        return
    if "bittorrent" in str(ndpi.get("proto", "")).lower():
        block_flow(event)


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def serve_connection(conn):
    while True:
        header = read_exact(conn, 5)
        if header is None:
            return
        try:
            length = int(header)
        except ValueError:
            log("ERROR", f"Некорректный заголовок длины от nDPId: {header!r}")
            return
        body = read_exact(conn, length)
        if body is None:
            return
        handle_event(body.decode("utf-8", errors="replace").rstrip("\n"))


def handle_conn(conn):
    try:
        serve_connection(conn)
    except Exception as e:
        log("ERROR", f"Ошибка обработки потока: {e}")
    finally:
        conn.close()
        log("WARN", "Соединение с nDPId потеряно, жду переподключения")


def main():
    sock_dir = os.path.dirname(SOCK_PATH)
    os.makedirs(sock_dir, exist_ok=True)
    os.chmod(sock_dir, 0o711)
    if os.path.exists(SOCK_PATH):
        os.remove(SOCK_PATH)

    ensure_rules()

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o666)
    srv.listen(16)
    log("SUCCESS", f"Слушатель запущен, ожидаю подключение nDPId на {SOCK_PATH}")

    while True:
        conn, _ = srv.accept()
        log("SUCCESS", "nDPId подключился к сокету")
        threading.Thread(target=handle_conn, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod 700 "$LISTENER"

# ------------------------------------------------------------
# Службы systemd
# ------------------------------------------------------------
log "Создание systemd-служб..."

# Наборы создаются до загрузки файрвола. Без этого rules.v4 с --match-set
# не загрузится после ребута (iptables-restore падает целиком).
cat << EOF > "$UNIT_DIR/bitblocker-ipset.service"
[Unit]
Description=Create and restore BitBlocker ipsets before firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service netfilter-persistent.service iptables.service ip6tables.service
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$CTL restore

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > "$UNIT_DIR/bitblocker-listener.service"
[Unit]
Description=BitBlocker — nDPId JSON listener and flow blocker
After=network.target bitblocker-ipset.service
Requires=bitblocker-ipset.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $LISTENER
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > "$NDPID_SERVICE"
[Unit]
Description=BitBlocker — nDPId traffic capture and classification
After=network.target bitblocker-listener.service
Requires=bitblocker-listener.service

[Service]
Type=simple
ExecStart=$NDPID_BIN -c $SOCK_PATH -i $IFACE $BPF_ARG
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > "$UNIT_DIR/bitblocker-dht-block.service"
[Unit]
Description=BitBlocker — refresh known DHT bootstrap node blocklist
After=network-online.target bitblocker-ipset.service
Wants=network-online.target
Requires=bitblocker-ipset.service

[Service]
Type=oneshot
ExecStart=$CTL update
EOF

cat << EOF > "$UNIT_DIR/bitblocker-dht-block.timer"
[Unit]
Description=Periodic refresh of BitBlocker DHT bootstrap blocklist

[Timer]
OnBootSec=1min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable bitblocker-ipset.service -q

# ------------------------------------------------------------
# Первый запуск: создаём наборы, переносим записи старых потоков,
# загружаем DHT и подменяем цепочку. Старые правила пока не трогаем.
# ------------------------------------------------------------
"$CTL" restore

migrate_old_flows() {
    local pair old new
    for pair in "BITBLOCKER-SRC4 bitblocker_src4" "BITBLOCKER-DST4 bitblocker_dst4" \
                "BITBLOCKER-SRC6 bitblocker_src6" "BITBLOCKER-DST6 bitblocker_dst6"; do
        old=${pair% *}; new=${pair#* }
        ipset list -n 2>/dev/null | grep -qx "$old" || continue
        ipset save "$old" | sed -n "s/^add $old /add $new /p" | ipset restore -exist 2>/dev/null
    done
}
migrate_old_flows

legacy_dht_present() {
    [ -f "$OLD_DHT" ] && return 0
    legacy_filter_chains_present && return 0
    legacy_ufw_dht_present && return 0
    return 1
}
LEGACY_DHT=0
legacy_dht_present && LEGACY_DHT=1

DHT_OK=1
echo -e "${B_YELLOW}Загрузка списка DHT-бутстрап нод и сборка цепочки BITBLOCKER...${NC}"
if ! "$CTL" update; then
    DHT_OK=0
    if [ "$LEGACY_DHT" -eq 1 ]; then
        err "Список DHT не загрузился. Старые DHT-правила оставлены, повторите установку позже."
    else
        warn "Список DHT не загрузился, повторная попытка будет при следующем запуске таймера."
    fi
fi

# ------------------------------------------------------------
# Миграция: удаление правил и наборов прошлой версии
# ------------------------------------------------------------
# Цепочка BITBLOCKER в raw уже пересобрана с новыми наборами. Старая цепочка в filter
# (самая первая версия) и DHT-правила удаляются только после успешной загрузки списка.
LEGACY_FILTER_BB=0
for cmd in iptables ip6tables; do
    command -v "$cmd" >/dev/null && $cmd -L BITBLOCKER -n &>/dev/null && LEGACY_FILTER_BB=1
done
if [ "$DHT_OK" -eq 1 ]; then
    remove_legacy_filter_chains
    remove_legacy_ufw_dht
else
    # Цепочку BITBLOCKER из filter убираем в любом случае: на неё могут ссылаться старые наборы
    if [ "$LEGACY_FILTER_BB" -eq 1 ]; then
        for cmd in iptables ip6tables; do
            command -v "$cmd" >/dev/null || continue
            if $cmd -L BITBLOCKER -n &>/dev/null; then
                for hook in INPUT OUTPUT FORWARD; do
                    while $cmd -D "$hook" -j BITBLOCKER 2>/dev/null; do :; done
                done
                $cmd -F BITBLOCKER 2>/dev/null
                $cmd -X BITBLOCKER 2>/dev/null
            fi
        done
    fi
fi
rm -f "$OLD_DHT"

destroy_sets "$OLD_SETS"
clean_ipsets_file 'BITBLOCKER-(SRC|DST|FLOW)[46]'
"$CTL" save-rules

# ------------------------------------------------------------
# Запуск служб
# ------------------------------------------------------------
systemctl enable bitblocker-listener.service -q
systemctl enable bitblocker-ndpid.service -q
systemctl enable bitblocker-dht-block.timer -q
systemctl restart bitblocker-listener.service
sleep 1
systemctl restart bitblocker-ndpid.service
systemctl restart bitblocker-dht-block.timer

echo -e "${B_YELLOW}Службы systemd 'bitblocker-ipset', 'bitblocker-listener', 'bitblocker-ndpid' и таймер 'bitblocker-dht-block' созданы и включены.${NC}"

if [ "$FW_MODE" = "iptables" ]; then
    systemctl enable netfilter-persistent 2>/dev/null || systemctl enable iptables-persistent 2>/dev/null
    if systemctl is-enabled netfilter-persistent &>/dev/null || systemctl is-enabled iptables-persistent &>/dev/null; then
        echo -e "${B_GREEN}netfilter-persistent включён — сохранённые правила переживут перезагрузку.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: не удалось включить netfilter-persistent. После ребута правила iptables могут слететь!${NC}"
        echo -e "${B_YELLOW}Проверьте вручную: systemctl status netfilter-persistent${NC}"
    fi
else
    systemctl enable ufw 2>/dev/null
    if systemctl is-enabled ufw &>/dev/null; then
        echo -e "${B_GREEN}UFW включён в автозагрузку.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: ufw не в автозагрузке. Выполните: ufw enable${NC}"
    fi
fi

echo
echo -e "${B_GREEN}${BOLD}Готово${NC}"
echo -e "${B_GREEN}Интерфейс анализа: ${IFACE}${NC}"
if [ -n "$BPF_ARG" ]; then
    echo -e "${B_GREEN}Фильтр захвата: ${BPF_FILTER}${NC}"
elif [ -n "$BPF_FILTER" ]; then
    echo -e "${B_YELLOW}Фильтр захвата задавался, но флаг не найден — анализируется весь трафик.${NC}"
else
    echo -e "${B_GREEN}Анализируется весь трафик на интерфейсе (без ограничения по портам).${NC}"
fi
echo -e "${B_GREEN}Обнаруженные BitTorrent-потоки блокируются точечно через ipset и таблицу raw.${NC}"
echo -e "${B_GREEN}DHT-бутстрап ноды блокируются отдельным набором ipset, список IP обновляется каждые 30 минут.${NC}"
echo
echo -e "${B_CYAN}Конфиг:${NC} ${BOLD}$CONF${NC}"
echo -e "${B_CYAN}Статус слушателя:${NC} ${BOLD}systemctl status bitblocker-listener${NC}"
echo -e "${B_CYAN}Статус nDPId:${NC} ${BOLD}systemctl status bitblocker-ndpid${NC}"
echo -e "${B_CYAN}Следующий запуск обновления DHT:${NC} ${BOLD}systemctl list-timers bitblocker-dht-block.timer${NC}"
echo -e "${B_CYAN}Правила (IPv4 / IPv6):${NC} ${BOLD}iptables -t raw -S BITBLOCKER${NC} / ${BOLD}ip6tables -t raw -S BITBLOCKER${NC}"
echo -e "${B_CYAN}Размер набора DHT:${NC} ${BOLD}ipset list -t bitblocker_dht4 | grep 'Number of entries'${NC}"
echo -e "${B_CYAN}Лог BitBlocker:${NC} ${BOLD}$LOG_FILE${NC}"
echo -e "${B_CYAN}Справка nDPId:${NC} ${BOLD}$NDPID_BIN -h${NC}"
echo
warn "Записи о потоках (bitblocker_src*/dst*) живут 24 часа и удаляются сами, размер цепочки BITBLOCKER фиксирован."
warn "Правила не зависят от UFW: они находятся в таблице raw и после ребута восстанавливаются службой bitblocker-ipset"
warn "(режим iptables: ещё и через rules.v4/v6, режим ufw: слушателем и таймером)."
warn "Ничего из этого не гарантирует блокировку сильно обфусцированного или зашифрованного трафика."

# ------------------------------------------------------------
# Проверка результата. Бэкап удаляется только если всё реально работает,
# иначе он остаётся для ручного отката.
# ------------------------------------------------------------
set_count() {
    ipset list -t "$1" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}'
}

verify_migration() {
    local s cmd fam dht unit rules
    for s in $NEW_SETS; do
        ipset list -n 2>/dev/null | grep -qx "$s" || { echo "нет набора $s"; return 1; }
    done
    [ "$(set_count bitblocker_dht4)" -gt 0 ] 2>/dev/null || { echo "набор bitblocker_dht4 пуст (список DHT не загружен)"; return 1; }

    for fam in 4 6; do
        if [ "$fam" = "4" ]; then cmd=iptables; else cmd=ip6tables; fi
        command -v "$cmd" >/dev/null || continue
        rules=$($cmd -t raw -S BITBLOCKER 2>/dev/null)
        echo "$rules" | grep -q "match-set bitblocker_src$fam src,src" || { echo "($cmd) в цепочке BITBLOCKER нет правила потоков"; return 1; }
        echo "$rules" | grep -q "match-set bitblocker_dht$fam dst,dst" || { echo "($cmd) в цепочке BITBLOCKER нет правила DHT"; return 1; }
        echo "$rules" | grep -q 'BITBLOCKER-' && { echo "($cmd) в цепочке остались ссылки на старые наборы"; return 1; }
        for hook in PREROUTING OUTPUT; do
            [ "$($cmd -t raw -S "$hook" 2>/dev/null | grep -cx -- "-A $hook -j BITBLOCKER")" -eq 1 ] \
                || { echo "($cmd) переход в $hook из raw: не одно правило"; return 1; }
        done
    done

    legacy_filter_chains_present && { echo "остались цепочки BITBLOCKER или BITBLOCKER-DHT в таблице filter"; return 1; }
    legacy_ufw_dht_present && { echo "в UFW остались правила BitBlocker-DHT"; return 1; }
    for s in $OLD_SETS; do
        ipset list -n 2>/dev/null | grep -qx "$s" && { echo "старый набор $s не удалён (на него ещё ссылаются правила)"; return 1; }
    done
    grep -qsE '^(create|add) BITBLOCKER-' /etc/iptables/ipsets && { echo "в /etc/iptables/ipsets остались записи старых наборов"; return 1; }
    [ -f "$OLD_DHT" ] && { echo "остался старый скрипт $OLD_DHT"; return 1; }
    for unit in bitblocker-ipset.service bitblocker-listener.service bitblocker-ndpid.service bitblocker-dht-block.timer; do
        systemctl is-enabled "$unit" &>/dev/null || { echo "$unit не включён"; return 1; }
    done
    return 0
}

if [ -d "$BACKUP_DIR" ]; then
    if REASON=$(verify_migration); then
        # Заодно убираем копии от прошлых неудачных попыток: теперь всё работает
        rm -rf "$CONF_DIR/backup"
        echo -e "${B_GREEN}Проверка пройдена, резервные копии удалены.${NC}"
    else
        echo -e "${B_YELLOW}Проверка не пройдена ($REASON), резервные копии оставлены: $BACKUP_DIR${NC}"
    fi
fi
