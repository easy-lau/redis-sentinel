#!/bin/bash

# Exit on any error
set -e
# Treat unset variables as an error
set -u
# Pipefail (bash 3.2+)
set -o pipefail

# --- Configuration (Defaults, can be overridden by user input) ---
DEFAULT_REDIS_VERSION="7.2.4" # Stable version, 7.4.3 was a typo for download.redis.io, latest is 7.2.x or unstable
DEFAULT_REDIS_PASSWORD="Authine2025"
DEFAULT_REDIS_PORT="6379"
DEFAULT_SENTINEL_PORT="26379"
DEFAULT_SENTINEL_QUORUM="2"
DEFAULT_SENTINEL_DOWN_AFTER_MS="30000"
DEFAULT_SENTINEL_PARALLEL_SYNCS="1"
DEFAULT_SENTINEL_FAILOVER_TIMEOUT="180000"

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    exit 1
}

# --- Main Script ---

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root or with sudo."
fi

# --- User Inputs ---
read -p "Enter Redis version to install [${DEFAULT_REDIS_VERSION}]: " REDIS_VERSION
REDIS_VERSION="${REDIS_VERSION:-${DEFAULT_REDIS_VERSION}}"
REDIS_DOWNLOAD_URL="http://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz"

# Read password securely if possible, otherwise normal read
REDIS_PASSWORD_INPUT="" # Initialize to avoid unbound variable error with set -u
if read -s -p "Enter Redis password (will not echo) [${DEFAULT_REDIS_PASSWORD}]: " REDIS_PASSWORD_INPUT && [ -n "$REDIS_PASSWORD_INPUT" ]; then
    REDIS_PASSWORD="$REDIS_PASSWORD_INPUT"
    echo
elif [ -z "${REDIS_PASSWORD_INPUT:-}" ]; then # If user just pressed Enter for default
    REDIS_PASSWORD="${DEFAULT_REDIS_PASSWORD}"
    echo # Ensure newline if default was taken silently
else # Fallback if -s is not supported or user typed then erased
    read -p "Enter Redis password [${DEFAULT_REDIS_PASSWORD}]: " REDIS_PASSWORD_INPUT
    REDIS_PASSWORD="${REDIS_PASSWORD_INPUT:-${DEFAULT_REDIS_PASSWORD}}"
fi


read -p "Enter Redis instance port [${DEFAULT_REDIS_PORT}]: " REDIS_PORT
REDIS_PORT="${REDIS_PORT:-${DEFAULT_REDIS_PORT}}"

NODE_TYPE=""
while [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "slave" ]]; do
    read -p "Install as (master/slave): " NODE_TYPE_INPUT
    NODE_TYPE=$(echo "${NODE_TYPE_INPUT:-}" | tr '[:upper:]' '[:lower:]')
    if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "slave" ]]; then
        log_warn "Invalid input. Please enter 'master' or 'slave'."
    fi
done

MASTER_IP_FOR_REPLICA=""
MASTER_IP_FOR_SENTINEL_MONITOR=""

if [ "$NODE_TYPE" == "slave" ]; then
    while [ -z "$MASTER_IP_FOR_REPLICA" ]; do
        read -p "Enter Master Node IP for replication (e.g., 192.168.1.100): " MASTER_IP_FOR_REPLICA
    done
    MASTER_IP_FOR_SENTINEL_MONITOR="$MASTER_IP_FOR_REPLICA"
else # Master node
    DETECTED_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./ && $i !~ /:/) {print $i; exit}}')
    DEFAULT_MASTER_IP_PROMPT=" (e.g., ${DETECTED_IP:-192.168.1.100})"
    while [ -z "$MASTER_IP_FOR_SENTINEL_MONITOR" ]; do
        read -p "Enter this Master's reachable IP for Sentinel monitoring${DEFAULT_MASTER_IP_PROMPT}: " MASTER_IP_FOR_SENTINEL_MONITOR_INPUT
        MASTER_IP_FOR_SENTINEL_MONITOR="${MASTER_IP_FOR_SENTINEL_MONITOR_INPUT:-${DETECTED_IP}}"
        if [ -z "$MASTER_IP_FOR_SENTINEL_MONITOR" ]; then
            log_warn "Master IP for Sentinel monitoring cannot be empty."
        fi
    done
    log_info "Using Master IP ${MASTER_IP_FOR_SENTINEL_MONITOR} for Sentinel monitoring."
fi

CONFIGURE_SENTINEL=""
while [[ "$CONFIGURE_SENTINEL" != "yes" && "$CONFIGURE_SENTINEL" != "no" ]]; do
    read -p "Configure and start Sentinel on this node? (yes/no) [yes]: " CONFIGURE_SENTINEL_INPUT
    CONFIGURE_SENTINEL=$(echo "${CONFIGURE_SENTINEL_INPUT:-yes}" | tr '[:upper:]' '[:lower:]')
done

# Initialize Sentinel config variables with defaults
SENTINEL_PORT="$DEFAULT_SENTINEL_PORT"
SENTINEL_QUORUM="$DEFAULT_SENTINEL_QUORUM"
SENTINEL_DOWN_AFTER_MS="$DEFAULT_SENTINEL_DOWN_AFTER_MS"
SENTINEL_PARALLEL_SYNCS="$DEFAULT_SENTINEL_PARALLEL_SYNCS"
SENTINEL_FAILOVER_TIMEOUT="$DEFAULT_SENTINEL_FAILOVER_TIMEOUT"

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    read -p "Enter Sentinel port [${DEFAULT_SENTINEL_PORT}]: " SENTINEL_PORT_INPUT
    SENTINEL_PORT="${SENTINEL_PORT_INPUT:-${DEFAULT_SENTINEL_PORT}}"

    read -p "Enter Sentinel quorum for 'mymaster' [${DEFAULT_SENTINEL_QUORUM}]: " SENTINEL_QUORUM_INPUT
    SENTINEL_QUORUM="${SENTINEL_QUORUM_INPUT:-${DEFAULT_SENTINEL_QUORUM}}"

    read -p "Enter Sentinel down-after-milliseconds for 'mymaster' [${DEFAULT_SENTINEL_DOWN_AFTER_MS}]: " SENTINEL_DOWN_AFTER_MS_INPUT
    SENTINEL_DOWN_AFTER_MS="${SENTINEL_DOWN_AFTER_MS_INPUT:-${DEFAULT_SENTINEL_DOWN_AFTER_MS}}"

    read -p "Enter Sentinel parallel-syncs for 'mymaster' [${DEFAULT_SENTINEL_PARALLEL_SYNCS}]: " SENTINEL_PARALLEL_SYNCS_INPUT
    SENTINEL_PARALLEL_SYNCS="${SENTINEL_PARALLEL_SYNCS_INPUT:-${DEFAULT_SENTINEL_PARALLEL_SYNCS}}"

    read -p "Enter Sentinel failover-timeout for 'mymaster' [${DEFAULT_SENTINEL_FAILOVER_TIMEOUT}]: " SENTINEL_FAILOVER_TIMEOUT_INPUT
    SENTINEL_FAILOVER_TIMEOUT="${SENTINEL_FAILOVER_TIMEOUT_INPUT:-${DEFAULT_SENTINEL_FAILOVER_TIMEOUT}}"
fi

SETUP_SYSTEMD=""
while [[ "$SETUP_SYSTEMD" != "yes" && "$SETUP_SYSTEMD" != "no" ]]; do
    read -p "Setup systemd services for auto-start? (yes/no) [yes]: " SETUP_SYSTEMD_INPUT
    SETUP_SYSTEMD=$(echo "${SETUP_SYSTEMD_INPUT:-yes}" | tr '[:upper:]' '[:lower:]')
done

# 1. Install Dependencies
log_info "Installing dependencies (gcc, tcl, wget, make)..."
if command -v yum &> /dev/null; then
    yum install -y gcc tcl wget make
elif command -v apt-get &> /dev/null; then
    apt-get update -y
    apt-get install -y gcc tcl wget make
else
    log_error "Cannot determine package manager. Please install gcc, tcl, wget, make manually."
fi

# 2. Download and Install Redis
log_info "Downloading Redis ${REDIS_VERSION}..."
cd /tmp
REDIS_TARBALL="redis-${REDIS_VERSION}.tar.gz"
REDIS_SRC_DIR="redis-${REDIS_VERSION}"

if [ ! -f "${REDIS_TARBALL}" ]; then
    # Using curl with -L to follow redirects, -f to fail silently on HTTP errors (error code will be non-zero)
    if curl -fSL -o "${REDIS_TARBALL}" "${REDIS_DOWNLOAD_URL}"; then
        log_info "Downloaded ${REDIS_TARBALL}"
    else
        log_error "Failed to download Redis from ${REDIS_DOWNLOAD_URL}. Status: $?. Please check the version and URL. (Attempted: ${REDIS_VERSION})"
    fi
else
    log_info "Redis tarball ${REDIS_TARBALL} already downloaded."
fi

log_info "Extracting and compiling Redis..."
if [ -d "${REDIS_SRC_DIR}" ]; then
    log_info "Removing existing source directory ${REDIS_SRC_DIR}..."
    rm -rf "${REDIS_SRC_DIR}"
fi
tar xzf "${REDIS_TARBALL}"
cd "${REDIS_SRC_DIR}"
make clean
make && make install
cd / # Go back to root directory or a neutral place
log_info "Redis ${REDIS_VERSION} installed successfully to /usr/local/bin."

# Create redis user and group (optional, but good practice if not using root for services)
REDIS_DEDICATED_USER="redis"
REDIS_DEDICATED_GROUP="redis"
if ! getent group "${REDIS_DEDICATED_GROUP}" > /dev/null; then
    log_info "Creating group '${REDIS_DEDICATED_GROUP}' (for potential non-root service setup)..."
    groupadd --system "${REDIS_DEDICATED_GROUP}"
fi
if ! getent passwd "${REDIS_DEDICATED_USER}" > /dev/null; then
    log_info "Creating user '${REDIS_DEDICATED_USER}' (for potential non-root service setup)..."
    useradd --system -g "${REDIS_DEDICATED_GROUP}" -s /bin/false -d "/var/lib/${REDIS_DEDICATED_USER}" "${REDIS_DEDICATED_USER}"
fi

# 3. Create Directories
log_info "Creating Redis directories..."
mkdir -p "/etc/redis"
mkdir -p "/var/redis/${REDIS_PORT}"
if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    mkdir -p "/var/redis/sentinel"
fi
mkdir -p "/var/log" # Ensure /var/log exists for log files
mkdir -p "/var/run" # Ensure /var/run exists for pid files

# 4. Configure Redis Instance
log_info "Configuring Redis ${NODE_TYPE} node on port ${REDIS_PORT}..."
REDIS_CONF_FILE="/etc/redis/${REDIS_PORT}.conf"
REDIS_LOG_FILE="/var/log/redis_${REDIS_PORT}.log"
REDIS_PID_FILE="/var/run/redis_${REDIS_PORT}.pid"

log_info "Creating Redis configuration file ${REDIS_CONF_FILE}..."
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
    # Slaves use replicaof. The port for replicaof should be the master's Redis port.
    # Assuming the master runs on the same port structure. If master port is different, this needs adjustment.
    # For simplicity, this script assumes master and slave use the same port number for Redis instances.
    echo "replicaof ${MASTER_IP_FOR_REPLICA} ${REDIS_PORT}" >> "${REDIS_CONF_FILE}"
    log_info "Configured as slave, replicating from ${MASTER_IP_FOR_REPLICA}:${REDIS_PORT}."
else
    log_info "Configured as master."
fi

# 5. Configure Sentinel (if chosen)
SENTINEL_CONF_FILE="/etc/redis/sentinel.conf"
SENTINEL_LOG_FILE="/var/log/redis-sentinel.log"
SENTINEL_PID_FILE="/var/run/redis-sentinel.pid"

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    log_info "Configuring Redis Sentinel on port ${SENTINEL_PORT}..."
    log_info "Creating Sentinel configuration file ${SENTINEL_CONF_FILE}..."
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
    log_info "Sentinel configured to monitor master 'mymaster' at ${MASTER_IP_FOR_SENTINEL_MONITOR}:${REDIS_PORT}."
fi

# 6. Setup Systemd Services or Start Manually
if [ "$SETUP_SYSTEMD" == "yes" ]; then
    log_info "Creating systemd service file for Redis: /etc/systemd/system/redis.service"
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

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    log_info "Enabling and starting Redis service (redis.service)..."
    systemctl enable redis.service
    systemctl restart redis.service # Use restart to ensure it picks up new configs if already running

    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "Creating systemd service file for Redis Sentinel: /etc/systemd/system/redis-sentinel.service"
        cat > /etc/systemd/system/redis-sentinel.service << EOF
[Unit]
Description=Redis Sentinel
After=network.target redis.service

[Service]
Type=forking
User=root
Group=root
ExecStart=/usr/local/bin/redis-sentinel ${SENTINEL_CONF_FILE}
# Sentinel shutdown command requires -p for port if not default 26379
# and if password protected, it needs to authenticate to the master it's monitoring.
# A simple 'shutdown' command to Sentinel itself is usually sufficient.
ExecStop=/usr/local/bin/redis-cli -p ${SENTINEL_PORT} shutdown
Restart=always
PIDFile=${SENTINEL_PID_FILE}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload # Reload again
        log_info "Enabling and starting Redis Sentinel service (redis-sentinel.service)..."
        systemctl enable redis-sentinel.service
        systemctl restart redis-sentinel.service # Use restart
    fi
    log_info "Systemd services configured and started."
else
    # Manual start
    log_info "Starting Redis server manually (daemonized)..."
    /usr/local/bin/redis-server "${REDIS_CONF_FILE}"
    log_info "Redis server started. Check PID: $(cat ${REDIS_PID_FILE} 2>/dev/null || echo 'PID file not found')"

    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "Starting Redis Sentinel manually (daemonized)..."
        /usr/local/bin/redis-sentinel "${SENTINEL_CONF_FILE}"
        log_info "Redis Sentinel started. Check PID: $(cat ${SENTINEL_PID_FILE} 2>/dev/null || echo 'PID file not found')"
    fi
    log_info "Redis instances started manually. Consider setting up systemd for production."
fi

# 7. Verification Instructions
log_info "--- Installation & Configuration Complete ---"
log_info "Redis Version: ${REDIS_VERSION}"
log_info "Node Type: ${NODE_TYPE}"
if [ "$NODE_TYPE" == "slave" ]; then
    log_info "Replicating from Master IP: ${MASTER_IP_FOR_REPLICA}:${REDIS_PORT}"
fi
log_info "Redis Port: ${REDIS_PORT}"
log_info "Redis Config: ${REDIS_CONF_FILE}"
log_info "Redis Log File: ${REDIS_LOG_FILE}"
log_info "Redis PID File: ${REDIS_PID_FILE}"
log_info "Redis Password: ${REDIS_PASSWORD}"
log_info ""
log_info "To verify Redis server:"
log_info "  redis-cli -p ${REDIS_PORT} -a \"${REDIS_PASSWORD}\" ping"
log_info "  redis-cli -p ${REDIS_PORT} -a \"${REDIS_PASSWORD}\" info replication"
log_info ""

if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
    log_info "Sentinel Port: ${SENTINEL_PORT}"
    log_info "Sentinel Config: ${SENTINEL_CONF_FILE}"
    log_info "Sentinel Log File: ${SENTINEL_LOG_FILE}"
    log_info "Sentinel PID File: ${SENTINEL_PID_FILE}"
    log_info "Sentinel monitors: mymaster at ${MASTER_IP_FOR_SENTINEL_MONITOR}:${REDIS_PORT} with quorum ${SENTINEL_QUORUM}"
    log_info "Sentinel down-after-milliseconds: ${SENTINEL_DOWN_AFTER_MS}"
    log_info "Sentinel parallel-syncs: ${SENTINEL_PARALLEL_SYNCS}"
    log_info "Sentinel failover-timeout: ${SENTINEL_FAILOVER_TIMEOUT}"
    log_info "To verify Sentinel:"
    log_info "  redis-cli -p ${SENTINEL_PORT} info sentinel"
    log_info ""
fi

if [ "$SETUP_SYSTEMD" == "yes" ]; then
    log_info "To check service status:"
    log_info "  systemctl status redis.service"
    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "  systemctl status redis-sentinel.service"
    fi
    log_info "To view logs with journalctl (if service output is redirected there by systemd):"
    log_info "  journalctl -u redis.service -f"
    if [ "$CONFIGURE_SENTINEL" == "yes" ]; then
        log_info "  journalctl -u redis-sentinel.service -f"
    fi
    log_info "Alternatively, check the log files directly: ${REDIS_LOG_FILE} and (if configured) ${SENTINEL_LOG_FILE}"
fi

log_info "Script finished."
