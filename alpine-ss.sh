#!/bin/sh
# Alpine-only Shadowsocks-rust installer (OpenRC)
# 同区域转发、无过墙需求：x86 用 AES-GCM，ARM 用 ChaCha20

set -eu

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

CONF_DIR="/etc/shadowsocks"
CONF="$CONF_DIR/config.json"
INIT="/etc/init.d/ss"
PIDFILE="/run/ss.pid"
LOG="/var/log/ss.log"

info()  { printf "%b%s%b\n" "$BLUE" "$*" "$PLAIN"; }
ok()    { printf "%b%s%b\n" "$GREEN" "$*" "$PLAIN"; }
warn()  { printf "%b%s%b\n" "$YELLOW" "$*" "$PLAIN"; }
err()   { printf "%b%s%b\n" "$RED" "$*" "$PLAIN"; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请用 root 运行"
        exit 1
    fi
}

need_alpine() {
    if [ ! -f /etc/alpine-release ]; then
        err "仅支持 Alpine Linux"
        exit 1
    fi
    if ! command -v rc-service >/dev/null 2>&1; then
        err "未找到 OpenRC (rc-service)"
        exit 1
    fi
}

arch() {
    uname -m
}

default_method() {
    case "$(arch)" in
        x86_64|amd64|i686|i386) echo "aes-256-gcm" ;;
        *) echo "chacha20-ietf-poly1305" ;;
    esac
}

ensure_repo() {
    ver=$(cut -d. -f1,2 /etc/alpine-release)
    if ! grep -qE 'community' /etc/apk/repositories; then
        echo "https://dl-cdn.alpinelinux.org/alpine/v${ver}/community" >> /etc/apk/repositories
        ok "已写入 community 源: v${ver}"
    fi
    apk update >/dev/null
}

install_pkg() {
    ensure_repo
    apk add --no-cache shadowsocks-rust || {
        err "apk 安装 shadowsocks-rust 失败，检查 community 源和架构"
        exit 1
    }
    if ! command -v ssserver >/dev/null 2>&1; then
        err "安装后仍没有 ssserver"
        exit 1
    fi
}

ask_port() {
    printf "SS 端口 [1-65535] (默认 8888): "
    read -r PORT </dev/tty 2>/dev/null || read -r PORT || true
    [ -z "${PORT:-}" ] && PORT=8888
    case "$PORT" in
        *[!0-9]*|"") err "端口必须是数字"; ask_port; return ;;
    esac
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        err "端口范围 1-65535"
        ask_port
        return
    fi
}

ask_method() {
    def=$(default_method)
    echo
    echo "加密（无过墙，按机器选性能）："
    echo "  1) aes-256-gcm              推荐 x86（AES-NI，同区域跑满首选）"
    echo "  2) aes-128-gcm              x86 略省 CPU，兼容略差于 256"
    echo "  3) chacha20-ietf-poly1305   推荐 ARM / 无 AES-NI"
    echo "  4) 2022-blake3-aes-256-gcm  SS2022，客户端需支持 2022"
    printf "选择 [1-4] (默认按架构: %s): " "$def"
    read -r pick </dev/tty 2>/dev/null || read -r pick || true
    [ -z "${pick:-}" ] && pick=0
    case "$pick" in
        1) METHOD="aes-256-gcm" ;;
        2) METHOD="aes-128-gcm" ;;
        3) METHOD="chacha20-ietf-poly1305" ;;
        4) METHOD="2022-blake3-aes-256-gcm" ;;
        0) METHOD="$def" ;;
        *) err "无效选择"; ask_method; return ;;
    esac
}

gen_pass() {
    # SS2022 的 256-gcm 需要 32 字节 key，用 32 字节随机再 base64
    if [ "$METHOD" = "2022-blake3-aes-256-gcm" ]; then
        PASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    else
        PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    fi
}

write_conf() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF" <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "password": "${PASS}",
  "method": "${METHOD}",
  "timeout": 300,
  "mode": "tcp_and_udp"
}
EOF
}

write_init() {
    SSBIN=$(command -v ssserver)
    cat > "$INIT" <<EOF
#!/sbin/openrc-run

name="ss"
command="${SSBIN}"
command_args="-c ${CONF}"
command_background=true
pidfile="${PIDFILE}"
retry="TERM/5/KILL/5"
output_log="${LOG}"
error_log="${LOG}"

depend() {
    need net
}
EOF
    chmod +x "$INIT"
}

stop_hard() {
    # zap only clears OpenRC state; stop orphaned processes before using it.
    rc-service ss stop >/dev/null 2>&1 || true
    if SSBIN=$(command -v ssserver); then
        if ! start-stop-daemon --stop --exec "$SSBIN" --retry TERM/5/KILL/5 --oknodo; then
            err "无法停止旧 ssserver 进程，未清除服务状态"
            return 1
        fi
    fi
    rm -f "$PIDFILE"
    rc-service ss zap >/dev/null 2>&1 || true
}

start_svc() {
    rc-update add ss default >/dev/null 2>&1 || true
    stop_hard || return 1
    if rc-service ss start; then
        sleep 1
        if rc-service ss status >/dev/null 2>&1; then
            ok "服务已启动"
            return 0
        fi
    fi
    err "服务启动失败，看日志: $LOG"
    tail -n 30 "$LOG" 2>/dev/null || true
    exit 1
}

fetch() {
    if command -v wget >/dev/null 2>&1; then
        wget -qO- -T 3 "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 3 "$1" 2>/dev/null
    else
        return 1
    fi
}

get_public_ip() {
    for url in \
        "https://ipinfo.io/ip" \
        "https://ip.sb" \
        "https://ifconfig.me" \
        "https://api.ipify.org" \
        "https://icanhazip.com"; do
        pubip=$(fetch "$url" 2>/dev/null || true)
        pubip=$(printf "%s" "$pubip" | tr -d '\r\n ')
        case "$pubip" in
            *[!0-9.]*|"") continue ;;
        esac
        echo "$pubip"
        return 0
    done
    return 1
}

show_info() {
    if [ ! -f "$CONF" ]; then
        err "未安装（没有 $CONF）"
        return 1
    fi
    ip4=$(get_public_ip)
    [ -z "$ip4" ] && ip4=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    [ -z "$ip4" ] && ip4="未知"
    PORT=$(awk -F: '/server_port/{gsub(/[ ,]/,"",$2); print $2}' "$CONF")
    METHOD=$(awk -F: '/"method"/{gsub(/[ ",]/,"",$2); print $2}' "$CONF")
    PASS=$(awk -F: '/"password"/{gsub(/[ ",]/,"",$2); print $2}' "$CONF")
    echo
    info "配置: $CONF"
    echo "  地址:   $ip4"
    echo "  端口:   $PORT"
    echo "  加密:   $METHOD"
    echo "  密码:   $PASS"
    echo "  模式:   tcp_and_udp"
    echo
    if command -v ss >/dev/null 2>&1; then
        if ss -lntup 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${PORT}\$"; then
            ok "端口 ${PORT} 正在监听"
        else
            warn "端口 $PORT 未在监听，检查: rc-service ss status"
        fi
    fi
}

do_install() {
    if [ -f "$INIT" ] && [ -f "$CONF" ]; then
        warn "已存在安装，将覆盖配置并重启"
    fi
    install_pkg
    ask_port
    ask_method
    gen_pass
    write_conf
    write_init
    start_svc
    ok "安装完成"
    show_info
}

do_uninstall() {
    printf "确认卸载 SS？[y/N]: "
    read -r a </dev/tty 2>/dev/null || read -r a || true
    case "$a" in
        y|Y)
            stop_hard
            rc-update del ss default >/dev/null 2>&1 || true
            rm -f "$INIT" "$PIDFILE"
            rm -rf "$CONF_DIR"
            ok "已卸载（未移除 shadowsocks-rust 软件包）"
            ;;
        *) warn "已取消" ;;
    esac
}

do_restart() {
    [ -f "$INIT" ] || { err "未安装"; exit 1; }
    start_svc
}

do_stop() {
    [ -f "$INIT" ] || { err "未安装"; exit 1; }
    stop_hard
    if rc-service ss status >/dev/null 2>&1; then
        err "仍在运行"
        exit 1
    fi
    ok "已停止"
}

port_in_use() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${1}\$"
}

do_change() {
    [ -f "$CONF" ] || { err "未安装"; exit 1; }
    ask_port
    ask_method
    gen_pass
    if port_in_use "$PORT"; then
        warn "端口 $PORT 当前已被占用（旧 ss 进程会被自动停掉；若属于其他程序请重选端口）"
    fi
    write_conf
    write_init
    start_svc
    ok "已更新"
    show_info
}

menu() {
    echo
    info "======== Alpine SS (shadowsocks-rust) ========"
    echo
    printf "  %b1)%b  安装\n" "$GREEN" "$PLAIN"
    printf "  %b2)%b  卸载\n" "$GREEN" "$PLAIN"
    printf "  %b3)%b  重启\n" "$GREEN" "$PLAIN"
    printf "  %b4)%b  停止\n" "$GREEN" "$PLAIN"
    printf "  %b5)%b  查看配置\n" "$GREEN" "$PLAIN"
    printf "  %b6)%b  改端口/加密（密码会重生成）\n" "$GREEN" "$PLAIN"
    printf "  %b0)%b  退出\n" "$GREEN" "$PLAIN"
    echo
    printf "  选择: "
    read -r ans </dev/tty 2>/dev/null || read -r ans || true
    case "${ans:-}" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_restart ;;
        4) do_stop ;;
        5) show_info ;;
        6) do_change ;;
        0) exit 0 ;;
        *) err "无效选择"; exit 1 ;;
    esac
}

need_root
need_alpine
menu
