#!/bin/bash

# Ensure the script's environment uses UTF-8
export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"

# Exit on any error
set -e
# Treat unset variables as an error
set -u
# Pipefail (bash 3.2+)
set -o pipefail

# --- Configuration (Defaults, can be overridden by user input) ---
DEFAULT_REDIS_VERSION="7.2.4" # 稳定版本
DEFAULT_REDIS_PASSWORD="Authine2025"
DEFAULT_REDIS_PORT="6379"
DEFAULT_SENTINEL_PORT="26379"
DEFAULT_SENTINEL_QUORUM="2"
DEFAULT_SENTINEL_DOWN_AFTER_MS="30000"
DEFAULT_SENTINEL_PARALLEL_SYNCS="1"
DEFAULT_SENTINEL_FAILOVER_TIMEOUT="180000"

# --- Helper Functions ---
log_info() {
    printf "[信息] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
    printf "[警告] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_error() {
    printf "[错误] %s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    exit 1
}

# --- Main Script ---

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本必须以 root 用户或使用 sudo 运行。"
fi

# --- User Inputs ---
printf "%s" "请输入要安装的 Redis 版本 [${DEFAULT_REDIS_VERSION}]: "
read REDIS_VERSION
REDIS_VERSION="${REDIS_VERSION:-${DEFAULT_REDIS_VERSION}}"
REDIS_DOWNLOAD_URL="http://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz"

# Read password securely if possible, otherwise normal read
REDIS_PASSWORD_INPUT="" # Initialize to avoid unbound variable error with set -u
printf "%s" "请输入 Redis 密码 (输入时不会显示) [${DEFAULT_REDIS_PASSWORD}]: "
if read -s REDIS_PASSWORD_INPUT && [ -n "$REDIS_PASSWORD_INPUT" ]; then
    REDIS_PASSWORD="$REDIS_PASSWORD_INPUT"
    printf "\n" # Newline after hidden input
elif [ -z "${REDIS_PASSWORD_INPUT:-}" ]; then # If user just pressed Enter for default
    REDIS_PASSWORD="${DEFAULT_REDIS_PASSWORD}"
    printf "\n" # Ensure newline if default was taken silently
else # Fallback if -s is not supported or user typed then erased
    printf "%s" "请输入 Redis 密码 [${DEFAULT_REDIS_PASSWORD}]: "
    read REDIS_PASSWORD_INPUT_FALLBACK # Use a different variable name to avoid issues with the previous -s read
    REDIS_PASSWORD="${REDIS_PASSWORD_INPUT_FALLBACK:-${DEFAULT_REDIS_PASSWORD}}"
fi


printf "%s" "请输入 Redis 实例端口号 [${DEFAULT_REDIS_PORT}]: "
read REDIS_PORT
REDIS_PORT="${REDIS_PORT:-${DEFAULT_REDIS_PORT}}"

NODE_TYPE=""
while [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "slave" ]]; do
    printf "%s" "请选择安装节点类型 (请输入 'master' 或 'slave'): "
    read NODE_TYPE_INPUT
    NODE_TYPE=$(echo "${NODE_TYPE_INPUT:-}" | tr '[:upper:]' '[:lower:]')
    if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "slave" ]]; then
        log_warn "输入无效。请输入 'master' 或 'slave'。"
    fi
done

MASTER_IP_FOR_REPLICA=""
MASTER_IP_FOR_SENTINEL_MONITOR=""

if [ "$NODE_TYPE" == "slave" ]; then
    while [ -z "$MASTER_IP_FOR_REPLICA" ]; do
        printf "%s" "请输入主节点 IP 地址用于复制 (例如: 192.168.1.100): "
        read MASTER_IP_FOR_REPLICA
    done
    MASTER_IP_FOR_SENTINEL_MONITOR="$MASTER_IP_FOR_REPLICA" # Sentinel 监控的 IP 与复制用的主节点 IP 相同
else # Master node
    DETECTED_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./ && $i !~ /:/) {print $i; exit}}')
    DEFAULT_MASTER_IP_PROMPT_TEXT=" (例如: ${DETECTED_IP:-192.168.1.100})" # Renamed variable to avoid conflict
    while [ -z "$MASTER_IP_FOR_SENTINEL_MONITOR" ]; do
        printf "%s" "请输入此主节点的可访问 IP (Sentinel 将用此 IP 监控主节点)${DEFAULT_MASTER_IP_PROMPT_TEXT}: "
        read MASTER_IP_FOR_SENTINEL_MONITOR_INPUT
        MASTER_IP_FOR_SENTINEL_MONITOR="${MASTER_IP_FOR_SENTINEL_MONITOR_INPUT:-${DETECTED_IP}}"
        if [ -z "$MASTER_IP_FOR_SENTINEL_MONITOR" ]; then
            log_warn "用于 Sentinel 监控的主节点 IP 不能为空。"
        fi
    done
    log_info "将使用主节点 IP ${MASTER_IP_FOR_SENTINEL_MONITOR} 进行 Sentinel 监控。"
fi

CONFIGURE_SENTINEL=""
while [[ "$CONFIGURE_SENTINEL" != "yes" && "$CONFIGURE_SENTINEL" != "no" ]]; do
    printf "%s" "是否在本节点配置并启动 Sentinel? (请输入 'yes' 或 'no') [yes]: "
    read CONFIGURE_SENTINEL_INPUT
    CONFIGURE_SENTINEL=$(echo "${CONFIGURE_SENTINEL_INPUT:-yes}" | tr '[:upper:]' '[:lower:]')
done

# Initialize Sentinel config variables with defaults
SENTINEL_PORT="$DEFAULT_SENTINEL_PORT"
SENTINEL_QUORUM="$DEFAULT_SENTINEL_QUORUM"
SENTINEL_DOWN_AFTER_MS="$DEFAULT_SENTINEL_DOWN_AFTER_MS"
SENTINEL_PARALLEL_SYNCS="$DEFAULT_SENTINEL_PARALLEL_SYNCS"
SENTINEL_FAILOVER_TIMEOUT="$DEFAULT_SENTINEL_FAILOVER_TIMEOUT"

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    printf "%s" "请输入 Sentinel 端口号 [${DEFAULT_SENTINEL_PORT}]: "
    read SENTINEL_PORT_INPUT
    SENTINEL_PORT="${SENTINEL_PORT_INPUT:-${DEFAULT_SENTINEL_PORT}}"

    printf "%s" "请输入 'mymaster' 的 Sentinel 仲裁数量 (quorum) [${DEFAULT_SENTINEL_QUORUM}]: "
    read SENTINEL_QUORUM_INPUT
    SENTINEL_QUORUM="${SENTINEL_QUORUM_INPUT:-${DEFAULT_SENTINEL_QUORUM}}"

    printf "%s" "请输入 'mymaster' 的 Sentinel 'down-after-milliseconds' (主观下线时间, 毫秒) [${DEFAULT_SENTINEL_DOWN_AFTER_MS}]: "
    read SENTINEL_DOWN_AFTER_MS_INPUT
    SENTINEL_DOWN_AFTER_MS="${SENTINEL_DOWN_AFTER_MS_INPUT:-${DEFAULT_SENTINEL_DOWN_AFTER_MS}}"

    printf "%s" "请输入 'mymaster' 的 Sentinel 'parallel-syncs' (并行同步数) [${DEFAULT_SENTINEL_PARALLEL_SYNCS}]: "
    read SENTINEL_PARALLEL_SYNCS_INPUT
    SENTINEL_PARALLEL_SYNCS="${SENTINEL_PARALLEL_SYNCS_INPUT:-${DEFAULT_SENTINEL_PARALLEL_SYNCS}}"

    printf "%s" "请输入 'mymaster' 的 Sentinel 'failover-timeout' (故障转移超时, 毫秒) [${DEFAULT_SENTINEL_FAILOVER_TIMEOUT}]: "
    read SENTINEL_FAILOVER_TIMEOUT_INPUT
    SENTINEL_FAILOVER_TIMEOUT="${SENTINEL_FAILOVER_TIMEOUT_INPUT:-${DEFAULT_SENTINEL_FAILOVER_TIMEOUT}}"
fi

SETUP_SYSTEMD=""
while [[ "$SETUP_SYSTEMD" != "yes" && "$SETUP_SYSTEMD" != "no" ]]; do
    printf "%s" "是否设置 systemd 服务以便开机自启? (请输入 'yes' 或 'no') [yes]: "
    read SETUP_SYSTEMD_INPUT
    SETUP_SYSTEMD=$(echo "${SETUP_SYSTEMD_INPUT:-yes}" | tr '[:upper:]' '[:lower:]')
done

# 1. Install Dependencies
log_info "正在安装依赖 (gcc, tcl, wget, make)..."
if command -v yum &> /dev/null; then
    yum install -y gcc tcl wget make
elif command -v apt-get &> /dev/null; then
    apt-get update -y
    apt-get install -y gcc tcl wget make
else
    log_error "无法确定包管理器。请手动安装 gcc, tcl, wget, make。"
fi

# 2. Download and Install Redis
log_info "正在下载 Redis ${REDIS_VERSION}..."
cd /tmp
REDIS_TARBALL="redis-${REDIS_VERSION}.tar.gz"
REDIS_SRC_DIR="redis-${REDIS_VERSION}"

if [ ! -f "${REDIS_TARBALL}" ]; then
    if curl -fSL -o "${REDIS_TARBALL}" "${REDIS_DOWNLOAD_URL}"; then
        log_info "已下载 ${REDIS_TARBALL}"
    else
        log_error "从 ${REDIS_DOWNLOAD_URL} 下载 Redis 失败。状态: $?. 请检查版本和 URL。(尝试版本: ${REDIS_VERSION})"
    fi
else
    log_info "Redis 压缩包 ${REDIS_TARBALL} 已存在。"
fi

log_info "正在解压和编译 Redis..."
if [ -d "${REDIS_SRC_DIR}" ]; then
    log_info "正在删除已存在的源码目录 ${REDIS_SRC_DIR}..."
    rm -rf "${REDIS_SRC_DIR}"
fi
tar xzf "${REDIS_TARBALL}"
cd "${REDIS_SRC_DIR}"
make clean
make && make install
cd /
log_info "Redis ${REDIS_VERSION} 已成功安装到 /usr/local/bin。"

REDIS_DEDICATED_USER="redis"
REDIS_DEDICATED_GROUP="redis"
if ! getent group "${REDIS_DEDICATED_GROUP}" > /dev/null; then
    log_info "正在创建用户组 '${REDIS_DEDICATED_GROUP}' (用于非 root 用户运行服务的可选设置)..."
    groupadd --system "${REDIS_DEDICATED_GROUP}"
fi
if ! getent passwd "${REDIS_DEDICATED_USER}" > /dev/null; then
    log_info "正在创建用户 '${REDIS_DEDICATED_USER}' (用于非 root 用户运行服务的可选设置)..."
    useradd --system -g "${REDIS_DEDICATED_GROUP}" -s /bin/false -d "/var/lib/${REDIS_DEDICATED_USER}" "${REDIS_DEDICATED_USER}"
fi

# 3. Create Directories
log_info "正在创建 Redis 目录..."
mkdir -p "/etc/redis"
mkdir -p "/var/redis/${REDIS_PORT}"
if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    mkdir -p "/var/redis/sentinel"
fi
mkdir -p "/var/log"
mkdir -p "/var/run"

# 4. Configure Redis Instance
log_info "正在配置 Redis ${NODE_TYPE} 节点, 端口 ${REDIS_PORT}..."
REDIS_CONF_FILE="/etc/redis/${REDIS_PORT}.conf"
REDIS_LOG_FILE="/var/log/redis_${REDIS_PORT}.log"
REDIS_PID_FILE="/var/run/redis_${REDIS_PORT}.pid"

log_info "正在创建 Redis 配置文件 ${REDIS_CONF_FILE}..."
cat > "${REDIS_CONF_FILE}" << EOF
bind 0.0.0.0
port ${REDIS_PORT}
daemonize yes
pidfile ${REDIS_PID_FILE}
logfile "${REDIS_LOG_FILE}"
dir /var/redis/${REDIS_PORT}
appendonly yes
requirepass "${REDIS_PASSWORD}"
masterauth "${REDIS_PASSWORD}"
EOF

if [ "$NODE_TYPE" == "slave" ]; then
    echo "replicaof ${MASTER_IP_FOR_REPLICA} ${REDIS_PORT}" >> "${REDIS_CONF_FILE}"
    log_info "已配置为从节点, 复制自 ${MASTER_IP_FOR_REPLICA}:${REDIS_PORT}。"
else
    log_info "已配置为主节点。"
fi

# 5. Configure Sentinel (if chosen)
SENTINEL_CONF_FILE="/etc/redis/sentinel.conf"
SENTINEL_LOG_FILE="/var/log/redis-sentinel.log"
SENTINEL_PID_FILE="/var/run/redis-sentinel.pid"

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    log_info "正在配置 Redis Sentinel, 端口 ${SENTINEL_PORT}..."
    log_info "正在创建 Sentinel 配置文件 ${SENTINEL_CONF_FILE}..."
    cat > "${SENTINEL_CONF_FILE}" << EOF
port ${SENTINEL_PORT}
daemonize yes
pidfile ${SENTINEL_PID_FILE}
logfile "${SENTINEL_LOG_FILE}"
dir /var/redis/sentinel
sentinel monitor mymaster ${MASTER_IP_FOR_SENTINEL_MONITOR} ${REDIS_PORT} ${SENTINEL_QUORUM}
sentinel auth-pass mymaster "${REDIS_PASSWORD}"
sentinel down-after-milliseconds mymaster ${SENTINEL_DOWN_AFTER_MS}
sentinel parallel-syncs mymaster ${SENTINEL_PARALLEL_SYNCS}
sentinel failover-timeout mymaster ${SENTINEL_FAILOVER_TIMEOUT}
EOF
    log_info "Sentinel 已配置监控主节点 'mymaster' (位于 ${MASTER_IP_FOR_SENTINEL_MONITOR}:${REDIS_PORT})。"
fi

# 6. Setup Systemd Services or Start Manually
if [ "$SETUP_SYSTEMD" == "yes" ]; then
    log_info "正在创建 Redis 的 systemd 服务文件: /etc/systemd/system/redis.service"
    cat > /etc/systemd/system/redis.service << EOF
[Unit]
Description=Redis In-Memory Data Store (Port ${REDIS_PORT})
After=network.target

[Service]
Type=forking
User=root
Group=root
ExecStart=/usr/local/bin/redis-server ${REDIS_CONF_FILE}
ExecStop=/usr/local/bin/redis-cli -p ${REDIS_PORT} -a "${REDIS_PASSWORD}" shutdown
Restart=on-failure
RestartSec=5
PIDFile=${REDIS_PID_FILE}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    log_info "正在重新加载 systemd 守护进程..."
    systemctl daemon-reload

    log_info "正在启用并启动 Redis 服务 (redis.service)..."
    systemctl enable redis.service
    systemctl restart redis.service

    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "正在创建 Redis Sentinel 的 systemd 服务文件: /etc/systemd/system/redis-sentinel.service"
        cat > /etc/systemd/system/redis-sentinel.service << EOF
[Unit]
Description=Redis Sentinel
After=network.target redis.service

[Service]
Type=forking
User=root
Group=root
ExecStart=/usr/local/bin/redis-sentinel ${SENTINEL_CONF_FILE}
ExecStop=/usr/local/bin/redis-cli -p ${SENTINEL_PORT} shutdown
Restart=always
PIDFile=${SENTINEL_PID_FILE}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        log_info "正在启用并启动 Redis Sentinel 服务 (redis-sentinel.service)..."
        systemctl enable redis-sentinel.service
        systemctl restart redis-sentinel.service
    fi
    log_info "Systemd 服务已配置并启动。"
else
    log_info "正在手动启动 Redis 服务器 (已后台运行)..."
    /usr/local/bin/redis-server "${REDIS_CONF_FILE}"
    log_info "Redis 服务器已启动。检查 PID: $(cat ${REDIS_PID_FILE} 2>/dev/null || printf '%s' 'PID 文件未找到')"

    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "正在手动启动 Redis Sentinel (已后台运行)..."
        /usr/local/bin/redis-sentinel "${SENTINEL_CONF_FILE}"
        log_info "Redis Sentinel 已启动。检查 PID: $(cat ${SENTINEL_PID_FILE} 2>/dev/null || printf '%s' 'PID 文件未找到')"
    fi
    log_info "Redis 实例已手动启动。生产环境建议设置 systemd 服务。"
fi

# 7. Verification Instructions
log_info "--- 安装与配置完成 ---"
log_info "Redis 版本: ${REDIS_VERSION}"
log_info "节点类型: ${NODE_TYPE}"
if [ "$NODE_TYPE" == "slave" ]; then
    log_info "从主节点 IP 复制: ${MASTER_IP_FOR_REPLICA}:${REDIS_PORT}"
fi
log_info "Redis 端口: ${REDIS_PORT}"
log_info "Redis 配置文件: ${REDIS_CONF_FILE}"
log_info "Redis 日志文件: ${REDIS_LOG_FILE}"
log_info "Redis PID 文件: ${REDIS_PID_FILE}"
log_info "Redis 密码: ${REDIS_PASSWORD}" # 或者出于安全考虑改为: log_info "Redis 密码: [已设置]"
printf "\n"
log_info "验证 Redis 服务器:"
log_info "  redis-cli -p ${REDIS_PORT} -a \"${REDIS_PASSWORD}\" ping"
log_info "  redis-cli -p ${REDIS_PORT} -a \"${REDIS_PASSWORD}\" info replication"
printf "\n"

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    log_info "Sentinel 端口: ${SENTINEL_PORT}"
    log_info "Sentinel 配置文件: ${SENTINEL_CONF_FILE}"
    log_info "Sentinel 日志文件: ${SENTINEL_LOG_FILE}"
    log_info "Sentinel PID 文件: ${SENTINEL_PID_FILE}"
    log_info "Sentinel 监控: mymaster 位于 ${MASTER_IP_FOR_SENTINEL_MONITOR}:${REDIS_PORT}, 仲裁数量 ${SENTINEL_QUORUM}"
    log_info "Sentinel down-after-milliseconds: ${SENTINEL_DOWN_AFTER_MS}"
    log_info "Sentinel parallel-syncs: ${SENTINEL_PARALLEL_SYNCS}"
    log_info "Sentinel failover-timeout: ${SENTINEL_FAILOVER_TIMEOUT}"
    log_info "验证 Sentinel:"
    log_info "  redis-cli -p ${SENTINEL_PORT} info sentinel"
    printf "\n"
fi

if [ "$SETUP_SYSTEMD" == "yes" ]; then
    log_info "检查服务状态:"
    log_info "  systemctl status redis.service"
    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "  systemctl status redis-sentinel.service"
    fi
    log_info "使用 journalctl 查看日志 (如果 systemd 将服务输出重定向到此处):"
    log_info "  journalctl -u redis.service -f"
    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "  journalctl -u redis-sentinel.service -f"
    fi
    log_info "或者, 直接检查日志文件: ${REDIS_LOG_FILE} 和 (如果已配置) ${SENTINEL_LOG_FILE}"
fi

log_info "脚本执行完毕。"
