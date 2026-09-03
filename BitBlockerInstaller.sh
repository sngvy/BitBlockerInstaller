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

# Показывает только процент/спиннер, полный лог — при ошибке
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
NDPID_BIN="/usr/local/bin/bitblocker-ndpid"
LISTENER_SCRIPT="/usr/local/bin/bitblocker-listener.py"
DHT_SCRIPT="/usr/local/bin/bitblocker-dht-block.sh"
SOCK_PATH="/run/bitblocker/ndpid.sock"
LOG_FILE="/var/log/bitblocker.log"
NDPID_SERVICE="/etc/systemd/system/bitblocker-ndpid.service"
IPSET_V4="BITBLOCKER-FLOW4"
IPSET_V6="BITBLOCKER-FLOW6"

migrate_legacy_bitblocker_chain() {
    local found=0
    for ipt in iptables ip6tables; do
        if $ipt -L BITBLOCKER -n &>/dev/null; then
            found=1
            for hook in INPUT OUTPUT FORWARD; do
                while $ipt -C "$hook" -j BITBLOCKER &>/dev/null; do
                    $ipt -D "$hook" -j BITBLOCKER
                done
            done
            $ipt -F BITBLOCKER
            $ipt -X BITBLOCKER
        fi
    done
    if [ "$found" -eq 1 ]; then
        if command -v iptables-save >/dev/null && [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        fi
        warn "Обнаружена и удалена устаревшая цепочка BITBLOCKER в таблице filter."
    fi
}

uninstall_bitblocker() {
    echo -e "${B_CYAN}${BOLD}Удаление BitBlocker${NC}"
    echo

    for unit in bitblocker-ndpid.service bitblocker-listener.service bitblocker-dht-block.timer bitblocker-dht-block.service; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
            systemctl stop "$unit" 2>/dev/null
            systemctl disable "$unit" 2>/dev/null
            rm -f "/etc/systemd/system/${unit}"
            ok "Служба ${unit} остановлена и удалена."
        fi
    done
    systemctl daemon-reload

    for ipt in iptables ip6tables; do
        if $ipt -t raw -L BITBLOCKER -n &>/dev/null; then
            for hook in PREROUTING OUTPUT; do
                while $ipt -t raw -C "$hook" -j BITBLOCKER &>/dev/null; do
                    $ipt -t raw -D "$hook" -j BITBLOCKER
                done
            done
            $ipt -t raw -F BITBLOCKER
            $ipt -t raw -X BITBLOCKER
            ok "Цепочка BITBLOCKER (raw) в $ipt удалена."
        fi
    done

    for ipt in iptables ip6tables; do
        if $ipt -L BITBLOCKER-DHT -n &>/dev/null; then
            for hook in INPUT OUTPUT FORWARD; do
                while $ipt -C "$hook" -j BITBLOCKER-DHT &>/dev/null; do
                    $ipt -D "$hook" -j BITBLOCKER-DHT
                done
            done
            $ipt -F BITBLOCKER-DHT
            $ipt -X BITBLOCKER-DHT
            ok "Цепочка BITBLOCKER-DHT (filter) в $ipt удалена."
        fi
    done

    if command -v iptables-save >/dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi

    for s in "$IPSET_V4" "$IPSET_V6"; do
        if ipset list "$s" &>/dev/null; then
            ipset destroy "$s" 2>/dev/null
            ok "ipset $s удалён."
        fi
    done

    if command -v ufw >/dev/null; then
        if grep -q 'BitBlocker-DHT' /etc/ufw/user.rules 2>/dev/null || grep -q 'BitBlocker-DHT' /etc/ufw/user6.rules 2>/dev/null; then
            sed -i '/BitBlocker-DHT/d' /etc/ufw/user.rules 2>/dev/null
            sed -i '/BitBlocker-DHT/d' /etc/ufw/user6.rules 2>/dev/null
            ufw reload 2>/dev/null
            ok "Правила UFW с меткой BitBlocker-DHT удалены."
        fi
    fi

    rm -f "$NDPID_BIN" "$LISTENER_SCRIPT" "$DHT_SCRIPT"
    ok "Бинарник и скрипты BitBlocker удалены."

    rm -rf "$INSTALL_DIR" /run/bitblocker
    ok "Каталоги сборки и сокета удалены."

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
read -p $'\033[1;33mВаш выбор [1-2]: \033[0m' ACTION_CHOICE

case "$ACTION_CHOICE" in
    2)
        uninstall_bitblocker
        exit 0
        ;;
    1) ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac
echo

migrate_legacy_bitblocker_chain

echo -e "${BOLD}Конфигурация BitBlocker${NC}"
echo
echo -e "BitBlocker работает на базе ${BOLD}nDPId${NC} (userspace DPI, без кастомного ядерного"
echo -e "модуля): nDPId захватывает трафик на интерфейсе и классифицирует потоки через nDPI,"
echo -e "а слушатель BitBlocker разбирает его JSON-события и точечно блокирует обнаруженные"
echo -e "BitTorrent-потоки через ipset+iptables (таблица RAW) с автоматическим"
echo -e "удалением записей по TTL и сбрасывает уже установленное соединение через conntrack."
echo -e "Отдельным демоном блокируются известные DHT-бутстрап ноды (с периодическим обновлением IP)."
echo

# Обнаружение существующей установки: вытаскиваем текущие настройки
# из уже развёрнутых bitblocker-dht-block.sh и bitblocker-ndpid.service, если есть.
EXISTING_FW_MODE=""
EXISTING_DHT_PORT_MODE=""
EXISTING_PORTS_INPUT=""
EXISTING_IFACE=""

if [ -f "$DHT_SCRIPT" ]; then
    echo -e "${B_YELLOW}Обнаружена существующая установка BitBlocker.${NC}"
    EXISTING_FW_MODE=$(grep -oP '(?<=^FW_MODE=")[^"]*' "$DHT_SCRIPT" 2>/dev/null)
    EXISTING_DHT_PORT_MODE=$(grep -oP '(?<=^DHT_PORT_MODE=")[^"]*' "$DHT_SCRIPT" 2>/dev/null)
    EXISTING_PORTS_INPUT=$(grep -oP '(?<=^PORTS_INPUT=")[^"]*' "$DHT_SCRIPT" 2>/dev/null)
    [ -n "$EXISTING_FW_MODE" ] && echo -e "  Текущий firewall:      $EXISTING_FW_MODE"
    [ -n "$EXISTING_DHT_PORT_MODE" ] && echo -e "  Текущий режим портов:  $EXISTING_DHT_PORT_MODE"
    [ -n "$EXISTING_PORTS_INPUT" ] && echo -e "  Текущие порты:         $EXISTING_PORTS_INPUT"
fi
if [ -f "$NDPID_SERVICE" ]; then
    EXISTING_IFACE=$(grep -oP '(?<=-i )\S+' "$NDPID_SERVICE" 2>/dev/null | head -1)
    [ -n "$EXISTING_IFACE" ] && echo -e "  Текущий интерфейс:     $EXISTING_IFACE"
fi
if [ -n "$EXISTING_FW_MODE" ]; then
    echo -e "${B_YELLOW}При переустановке можно оставить значения без изменений (Enter) или задать новые.${NC}"
fi
echo

echo -e "${B_CYAN}Какой firewall используется на сервере для прочих правил?${NC}"
echo -e "1) iptables (прямые правила + iptables-persistent)"
echo -e "2) ufw"
if [ -n "$EXISTING_FW_MODE" ]; then
    read -p $'\033[1;33m'"Ваш выбор [1-2] (Enter — оставить текущий: $EXISTING_FW_MODE): "$'\033[0m' FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        case "$EXISTING_FW_MODE" in
            iptables) FW_CHOICE=1 ;;
            ufw) FW_CHOICE=2 ;;
        esac
    fi
else
    read -p $'\033[1;33mВаш выбор [1-2]: \033[0m' FW_CHOICE
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
if [ -n "$EXISTING_DHT_PORT_MODE" ]; then
    read -p $'\033[1;33m'"Ваш выбор [1-3] (Enter — оставить текущий: $EXISTING_DHT_PORT_MODE): "$'\033[0m' BLOCK_CHOICE
    if [ -z "$BLOCK_CHOICE" ]; then
        case "$EXISTING_DHT_PORT_MODE" in
            only) BLOCK_CHOICE=1 ;;
            all) BLOCK_CHOICE=2 ;;
            except) BLOCK_CHOICE=3 ;;
        esac
    fi
else
    read -p $'\033[1;33mВаш выбор [1-3]: \033[0m' BLOCK_CHOICE
fi

# Фильтрует на уровне захвата пакетов (libpcap), не самой DPI-проверки
bpf_clauses() {
    local input clause list=""
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

BPF_FILTER=""
DHT_PORT_MODE="all"
DHT_PORTS=""
case "$BLOCK_CHOICE" in
    1)
        echo
        echo -e "${B_CYAN}Укажите порты. Поддерживаются:${NC}"
        echo -e "  - диапазон:        6881-6889"
        echo -e "  - список через запятую: 6881,6969,51413"
        echo -e "  - смешанный вариант:    6881-6889,51413,6969"
        if [ -n "$EXISTING_PORTS_INPUT" ]; then
            read -p $'\033[1;33m'"Порты (Enter — оставить текущие: $EXISTING_PORTS_INPUT): "$'\033[0m' PORTS_INPUT
            PORTS_INPUT="${PORTS_INPUT:-$EXISTING_PORTS_INPUT}"
        else
            read -p $'\033[1;33mПорты [по умолчанию 6881-6889]: \033[0m' PORTS_INPUT
            PORTS_INPUT="${PORTS_INPUT:-6881-6889}"
        fi
        CLAUSES=$(bpf_clauses "$PORTS_INPUT")
        BPF_FILTER="(tcp or udp) and ($CLAUSES)"
        DHT_PORT_MODE="only"
        DHT_PORTS=$(echo "$PORTS_INPUT" | tr -d ' ' | sed 's/-/:/g')
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
        if [ -n "$EXISTING_PORTS_INPUT" ]; then
            read -p $'\033[1;33m'"Порты для исключения (Enter — оставить текущие: $EXISTING_PORTS_INPUT): "$'\033[0m' PORTS_INPUT
            PORTS_INPUT="${PORTS_INPUT:-$EXISTING_PORTS_INPUT}"
        else
            read -p $'\033[1;33mПорты для исключения: \033[0m' PORTS_INPUT
        fi
        if [ -z "$PORTS_INPUT" ]; then
            err "Нужно указать хотя бы один порт для исключения."
            exit 1
        fi
        CLAUSES=$(bpf_clauses "$PORTS_INPUT")
        BPF_FILTER="not ($CLAUSES)"
        DHT_PORT_MODE="except"
        DHT_PORTS=$(echo "$PORTS_INPUT" | tr -d ' ' | sed 's/-/:/g')
        ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac

echo
DETECTED_IFACE=$(ip -4 route list default 2>/dev/null | awk '{print $5; exit}')
SUGGESTED_IFACE="${EXISTING_IFACE:-$DETECTED_IFACE}"
if [ -n "$SUGGESTED_IFACE" ]; then
    read -p $'\033[1;33m'"Интерфейс для анализа трафика (Enter — $SUGGESTED_IFACE): "$'\033[0m' IFACE_INPUT
    IFACE="${IFACE_INPUT:-$SUGGESTED_IFACE}"
else
    err "Не удалось автоматически определить интерфейс с маршрутом по умолчанию."
    read -p $'\033[1;33mУкажите интерфейс вручную (например eth0): \033[0m' IFACE
    if [ -z "$IFACE" ]; then
        err "Интерфейс не указан. Выход."
        exit 1
    fi
fi
ok "Интерфейс для анализа трафика: ${IFACE}"

export DEBIAN_FRONTEND=noninteractive

log "Обновление списка пакетов и установка зависимостей..."
apt-get update -qq

BASE_PKGS="build-essential git cmake gettext flex bison libtool autoconf automake pkg-config libpcap-dev libjson-c-dev libnuma-dev libpcre2-dev libmaxminddb-dev librrd-dev python3 conntrack ipset wget unzip util-linux dnsutils"

if [ "$FW_MODE" = "ufw" ]; then
    apt-get install -y -qq ufw $BASE_PKGS
else
    mkdir -p /etc/iptables
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get install -y -qq iptables iptables-persistent $BASE_PKGS
fi

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
    if ! run_with_progress "Клонирование nDPId" git clone --recursive "$NDPID_REPO" "$INSTALL_DIR"; then
        exit 1
    fi

    cd "$INSTALL_DIR" || exit 1
    mkdir -p build
    cd build || exit 1

    if ! run_with_progress "Настройка cmake (-DBUILD_NDPI=ON)" cmake -DBUILD_NDPI=ON -DBUILD_EXAMPLES=OFF ..; then
        exit 1
    fi
    if ! run_with_progress "Сборка nDPId" make -j"$(nproc)"; then
        exit 1
    fi

    BUILT_BIN=$(find . -maxdepth 2 -type f -name 'nDPId' -perm -u+x | head -n1)
    if [ -z "$BUILT_BIN" ]; then
        err "Не нашёл собранный бинарник nDPId после сборки."
        exit 1
    fi
    cp "$BUILT_BIN" "$NDPID_BIN"
    chmod +x "$NDPID_BIN"
    ok "nDPId собран и установлен в ${NDPID_BIN}."

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
        warn "nDPId будет анализировать ВЕСЬ трафик на интерфейсе (как в режиме «по всем портам»)."
    else
        ok "Найден флаг BPF-фильтра в справке nDPId: $BPF_FLAG"
        BPF_ARG="$BPF_FLAG \"$BPF_FILTER\""
    fi
fi

log "Установка слушателя BitBlocker: $LISTENER_SCRIPT"

cat << 'PYEOF' > "$LISTENER_SCRIPT"
#!/usr/bin/env python3
"""Слушает JSON-события nDPId и дропает обнаруженные BitTorrent-потоки."""

import json
import os
import socket
import subprocess
import sys
import time

SOCK_PATH = "/run/bitblocker/ndpid.sock"
LOG_FILE = "/var/log/bitblocker.log"
DETECT_EVENTS = {"detected", "guessed", "detection-update"}

IPSET_TIMEOUT = "3600"
IPSET_V4 = "BITBLOCKER-FLOW4"
IPSET_V6 = "BITBLOCKER-FLOW6"

_seen_flows = set()


def log(tag, msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{tag}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd):
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def check(cmd):
    result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def ensure_chain():
    run(["ipset", "create", IPSET_V4, "hash:ip,port,ip,port", "timeout", IPSET_TIMEOUT, "family", "inet"])
    run(["ipset", "create", IPSET_V6, "hash:ip,port,ip,port", "timeout", IPSET_TIMEOUT, "family", "inet6"])

    for ipt, ipset_name in (("iptables", IPSET_V4), ("ip6tables", IPSET_V6)):
        run([ipt, "-t", "raw", "-N", "BITBLOCKER"])

        for chain in ("PREROUTING", "OUTPUT"):
            if not check([ipt, "-t", "raw", "-C", chain, "-j", "BITBLOCKER"]):
                run([ipt, "-t", "raw", "-I", chain, "-j", "BITBLOCKER"])

        for direction in ("src,dst", "dst,src"):
            if not check([ipt, "-t", "raw", "-C", "BITBLOCKER", "-m", "set",
                          "--match-set", ipset_name, direction, "-j", "DROP"]):
                run([ipt, "-t", "raw", "-A", "BITBLOCKER", "-m", "set",
                     "--match-set", ipset_name, direction, "-j", "DROP"])


def block_flow(event):
    src_ip = event.get("src_ip")
    dst_ip = event.get("dst_ip")
    src_port = event.get("src_port")
    dst_port = event.get("dst_port")
    l4 = event.get("l4_proto")
    if not all([src_ip, dst_ip, src_port, dst_port, l4]) or l4 not in ("tcp", "udp"):
        return

    key = (src_ip, src_port, dst_ip, dst_port, l4)
    if key in _seen_flows:
        return
    _seen_flows.add(key)

    is_v6 = ":" in src_ip
    ipset_name = IPSET_V6 if is_v6 else IPSET_V4
    ipt = "ip6tables" if is_v6 else "iptables"

    run(["ipset", "add", ipset_name,
         f"{src_ip},{l4}:{src_port},{dst_ip},{l4}:{dst_port}", "-exist"])

    run(["conntrack", "-D", "-p", l4, "-s", src_ip, "--sport", str(src_port),
         "-d", dst_ip, "--dport", str(dst_port)])

    proto_name = event.get("ndpi", {}).get("proto", "BitTorrent")
    log("SUCCESS", f"Заблокирован поток {proto_name}: {src_ip}:{src_port} -> {dst_ip}:{dst_port} ({l4})")


def handle_event(raw_bytes):
    try:
        event = json.loads(raw_bytes)
    except json.JSONDecodeError:
        return

    if event.get("flow_event_name") not in DETECT_EVENTS:
        return

    ndpi = event.get("ndpi")
    if not ndpi:
        return

    proto = ndpi.get("proto", "")
    if "bittorrent" in proto.lower():
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


def main():
    os.makedirs(os.path.dirname(SOCK_PATH), exist_ok=True)
    if os.path.exists(SOCK_PATH):
        os.remove(SOCK_PATH)

    ensure_chain()

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o666)
    srv.listen(1)
    log("SUCCESS", f"Слушатель запущен, ожидаю подключение nDPId на {SOCK_PATH}")

    while True:
        conn, _ = srv.accept()
        log("SUCCESS", "nDPId подключился к сокету")
        try:
            serve_connection(conn)
        except Exception as e:
            log("ERROR", f"Ошибка обработки потока: {e}")
        finally:
            conn.close()
            log("ERROR", "Соединение с nDPId потеряно, жду переподключения")


if __name__ == "__main__":
    sys.exit(main())
PYEOF

chmod +x "$LISTENER_SCRIPT"

log "Установка демона блокировки DHT-бутстрапов: $DHT_SCRIPT"

cat << EOF > "$DHT_SCRIPT"
#!/bin/bash
LOG_FILE="/var/log/bitblocker.log"
CHAIN="BITBLOCKER-DHT"
FW_MODE="$FW_MODE"
DHT_PORT_MODE="$DHT_PORT_MODE"
DHT_PORTS="$DHT_PORTS"
PORTS_INPUT="$PORTS_INPUT"

# Каждая нода — свой порт (не все совпадают: dht.libtorrent.org слушает не 6881)
DHT_HOSTS=(
    "router.bittorrent.com:6881"
    "router.utorrent.com:6881"
    "dht.transmissionbt.com:6881"
    "dht.aelitis.com:6881"
    "dht.libtorrent.org:25401"
)

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') [\$1] \$2" | tee -a "\$LOG_FILE"; }

COUNT=0

if [ "\$FW_MODE" = "ufw" ]; then
    sed -i '/BitBlocker-DHT/d' /etc/ufw/user.rules 2>/dev/null
    sed -i '/BitBlocker-DHT/d' /etc/ufw/user6.rules 2>/dev/null
    for entry in "\${DHT_HOSTS[@]}"; do
        host="\${entry%%:*}"
        port="\${entry##*:}"
        IPS=\$(getent ahosts "\$host" 2>/dev/null | awk '{print \$1}' | sort -u)
        if [ -z "\$IPS" ]; then
            log "ERROR" "Не удалось разрешить \$host"
            continue
        fi
        while IFS= read -r ip; do
            [ -z "\$ip" ] && continue
            if [ "\$DHT_PORT_MODE" = "only" ] && [ -n "\$DHT_PORTS" ]; then
                IFS=',' read -ra SRC_ARR <<< "\$DHT_PORTS"
                for sp in "\${SRC_ARR[@]}"; do
                    ufw prepend deny out from any port "\$sp" to "\$ip" port "\$port" proto udp comment 'BitBlocker-DHT'
                done
            else
                ufw prepend deny out to "\$ip" port "\$port" proto udp comment 'BitBlocker-DHT'
            fi
            conntrack -D -p udp -d "\$ip" --dport "\$port" 2>/dev/null
            COUNT=\$((COUNT + 1))
        done <<< "\$IPS"
    done
    # Прибавляем последними, чтобы prepend поставил их ВЫШЕ deny-правил (приоритет)
    if [ "\$DHT_PORT_MODE" = "except" ] && [ -n "\$DHT_PORTS" ]; then
        IFS=',' read -ra EP_ARR <<< "\$DHT_PORTS"
        for p in "\${EP_ARR[@]}"; do
            ufw prepend allow out from any port "\$p" to any comment 'BitBlocker-DHT'
        done
    fi
    ufw reload
else
    for ipt in iptables ip6tables; do
        if ! \$ipt -L "\$CHAIN" -n &>/dev/null; then
            \$ipt -N "\$CHAIN"
        else
            \$ipt -F "\$CHAIN"
        fi
        for chain in INPUT OUTPUT FORWARD; do
            \$ipt -C "\$chain" -j "\$CHAIN" &>/dev/null || \$ipt -I "\$chain" -j "\$CHAIN"
        done
        # RETURN должен идти ДО DROP-правил (проверяются по порядку добавления)
        if [ "\$DHT_PORT_MODE" = "except" ] && [ -n "\$DHT_PORTS" ]; then
            \$ipt -A "\$CHAIN" -p udp -m multiport --sports "\$DHT_PORTS" -j RETURN
        fi
    done
    for entry in "\${DHT_HOSTS[@]}"; do
        host="\${entry%%:*}"
        port="\${entry##*:}"
        IPS=\$(getent ahosts "\$host" 2>/dev/null | awk '{print \$1}' | sort -u)
        if [ -z "\$IPS" ]; then
            log "ERROR" "Не удалось разрешить \$host"
            continue
        fi
        while IFS= read -r ip; do
            [ -z "\$ip" ] && continue
            ipt_bin="iptables"
            [[ "\$ip" == *:* ]] && ipt_bin="ip6tables"
            if [ "\$DHT_PORT_MODE" = "only" ] && [ -n "\$DHT_PORTS" ]; then
                \$ipt_bin -A "\$CHAIN" -p udp -m multiport --sports "\$DHT_PORTS" -d "\$ip" --dport "\$port" -j DROP
            else
                \$ipt_bin -A "\$CHAIN" -d "\$ip" -p udp --dport "\$port" -j DROP
            fi
            conntrack -D -p udp -d "\$ip" --dport "\$port" 2>/dev/null
            COUNT=\$((COUNT + 1))
        done <<< "\$IPS"
    done
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
fi

log "SUCCESS" "DHT-бутстрап заблокирован: \$COUNT адресов из \${#DHT_HOSTS[@]} хостов (\$FW_MODE, режим портов: \$DHT_PORT_MODE)"
EOF

chmod +x "$DHT_SCRIPT"

apt-get install -y logrotate -qq

# Хранит только последние 7 дней
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

log "Создание systemd-служб..."

cat << EOF > /etc/systemd/system/bitblocker-listener.service
[Unit]
Description=BitBlocker — nDPId JSON listener and flow blocker
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $LISTENER_SCRIPT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/systemd/system/bitblocker-ndpid.service
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

cat << EOF > /etc/systemd/system/bitblocker-dht-block.service
[Unit]
Description=BitBlocker — refresh known DHT bootstrap node blocklist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DHT_SCRIPT
EOF

cat << EOF > /etc/systemd/system/bitblocker-dht-block.timer
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
systemctl enable bitblocker-listener.service -q
systemctl enable bitblocker-ndpid.service -q
systemctl enable bitblocker-dht-block.timer -q
systemctl restart bitblocker-listener.service
sleep 1
systemctl restart bitblocker-ndpid.service
systemctl restart bitblocker-dht-block.timer
systemctl start bitblocker-dht-block.service

echo -e "${B_YELLOW}Службы systemd 'bitblocker-listener', 'bitblocker-ndpid' и таймер 'bitblocker-dht-block' созданы и включены.${NC}"

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
echo -e "${B_GREEN}Обнаруженные BitTorrent-потоки блокируются точечно через ipset + RAW (DROP + conntrack -D).${NC}"
echo -e "${B_GREEN}DHT-бутстрап ноды блокируются статически, обновление списка IP — каждые 30 минут.${NC}"
echo
echo -e "${B_CYAN}Статус слушателя:${NC} ${BOLD}systemctl status bitblocker-listener${NC}"
echo -e "${B_CYAN}Статус nDPId:${NC} ${BOLD}systemctl status bitblocker-ndpid${NC}"
echo -e "${B_CYAN}Статус DHT-таймера:${NC} ${BOLD}systemctl status bitblocker-dht-block.timer${NC}"
echo -e "${B_CYAN}Следующий запуск обновления DHT:${NC} ${BOLD}systemctl list-timers bitblocker-dht-block.timer${NC}"
echo -e "${B_CYAN}Текущие правила (IPv4):${NC} ${BOLD}iptables -t raw -L BITBLOCKER -n -v${NC}"
echo -e "${B_CYAN}Текущие правила (IPv6):${NC} ${BOLD}ip6tables -t raw -L BITBLOCKER -n -v${NC}"
echo -e "${B_CYAN}Активные заблокированные потоки:${NC} ${BOLD}ipset list $IPSET_V4${NC} / ${BOLD}ipset list $IPSET_V6${NC}"
if [ "$FW_MODE" = "ufw" ]; then
    echo -e "${B_CYAN}Правила DHT-блокировки:${NC} ${BOLD}ufw status | grep BitBlocker-DHT${NC}"
    echo -e "${B_YELLOW}Примечание: BITBLOCKER (точечные потоки) всегда управляется напрямую через${NC}"
    echo -e "${B_YELLOW}iptables/ip6tables (таблица RAW + ipset) — у UFW нет механизма для этого.${NC}"
    echo -e "${B_YELLOW}А вот BITBLOCKER-DHT — статичный список IP, поэтому идёт через сам UFW (ufw deny).${NC}"
else
    echo -e "${B_CYAN}Правила DHT-блокировки:${NC} ${BOLD}iptables -L BITBLOCKER-DHT -n -v${NC}"
fi
echo -e "${B_CYAN}Лог BitBlocker:${NC} ${BOLD}$LOG_FILE${NC}"
echo -e "${B_CYAN}Справка nDPId:${NC} ${BOLD}$NDPID_BIN -h${NC}"
echo
warn "Записи в ipset ($IPSET_V4/$IPSET_V6) имеют TTL 3600 секунд и удаляются сами, размер"
warn "цепочки BITBLOCKER в iptables/ip6tables фиксирован и не растёт со временем."
warn "DHT-блокировка (BITBLOCKER-DHT) статическая и не зависит от DPI — переживает перезагрузку"
warn "и сама переустанавливается при первом запуске таймера (до 1 минуты после старта системы)."
warn "Ничего из этого не гарантирует 100% блокировку сильно обфусцированного/зашифрованного трафика."
