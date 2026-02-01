#!/bin/bash

# =================================================================
# 脚本名称: mysql_ultimate_final_v3.sh
# 兼容性: Ubuntu 20/22/24, RHEL/CentOS/Rocky/Alma 7/8/9
# 功能: 自动获取最新版、解决 Ubuntu 24.04 库缺失、全自动优化
# =================================================================

set -e

# --- 1. 配置区 ---
NEW_MYSQL_PASS="MyNewPass@123" 
DATA_DIR="/data"
MYSQL_BASE="/usr/local/mysql"
USER_VER=$1  # 运行脚本可跟版本号，如: bash install.sh 8.0.35

# --- 2. 环境初始化 & 库映射修复 ---
init_env() {
    echo ">>> [1/6] 正在检查系统环境并修复依赖..."
    if [[ "$EUID" -ne 0 ]]; then echo "错误: 请以 root 运行"; exit 1; fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VER=$VERSION_ID
    else
        echo "无法识别系统类型"; exit 1
    fi

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -qq
        # 安装基础工具和最新库
        apt-get install -y wget curl gawk xz-utils logrotate libnuma1 libaio1t64 libncurses6 libtinfo6 2>/dev/null || \
        apt-get install -y wget curl gawk xz-utils logrotate libnuma1 libaio1 libncurses5 libtinfo5
        
        # 【关键】修复 Ubuntu 24.04+ 的库映射
        echo ">>> 正在创建动态库兼容软链接..."
        # 寻找 libaio.so.1t64 的位置并链接为 libaio.so.1
        LOCAL_LIBAIO=$(find /usr/lib/x86_64-linux-gnu -name "libaio.so.1*" | head -n 1)
        if [ -n "$LOCAL_LIBAIO" ]; then
            ln -sf "$LOCAL_LIBAIO" /usr/lib/x86_64-linux-gnu/libaio.so.1
        fi
        
        # 修复 ncurses 5 缺失
        ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || true
        ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5 2>/dev/null || true
        
        ldconfig # 刷新系统库缓存

    elif [[ "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        yum install -y epel-release >/dev/null
        yum install -y wget curl gawk xz libaio numactl bzip2 logrotate >/dev/null
        yum install -y ncurses-compat-libs 2>/dev/null || yum install -y ncurses-libs
    fi

    # 目录与用户
    mkdir -p $DATA_DIR/{software,mysql} $DATA_DIR/mysql/{data,log,tmp}
    if ! id mysql &>/dev/null; then
        useradd -M -s /sbin/nologin mysql
    fi
}

# --- 3. 下载与稳健解压 ---
download_mysql() {
    echo ">>> [2/6] 准备下载 MySQL..."
    cd $DATA_DIR/software/

    if [ -z "$USER_VER" ]; then
        # 实时探测 8.0 系列最新版
        REAL_VER=$(curl -s https://downloads.mysql.com/archives/community/ | grep -oE '8\.0\.[0-9]+' | head -1)
    else
        REAL_VER=$USER_VER
    fi

    PKG="mysql-${REAL_VER}-linux-glibc2.17-x86_64.tar.xz"
    URL="https://downloads.mysql.com/archives/get/p/23/file/${PKG}"

    if [ ! -f "$PKG" ]; then
        echo ">>> 正在下载: $PKG ..."
        wget --no-check-certificate -c "$URL"
    fi

    if [ ! -d "$MYSQL_BASE/bin" ]; then
        echo ">>> 正在解压安装到 $MYSQL_BASE ..."
        mkdir -p "$MYSQL_BASE"
        # 使用 --strip-components=1 直接解压到目标目录，避免 mv 报错
        tar -xJf "$PKG" -C "$MYSQL_BASE" --strip-components=1
    fi
    
    chown -R mysql:mysql "$MYSQL_BASE" "$DATA_DIR/mysql"
}

# --- 4. 配置文件生成 ---
generate_cnf() {
    echo ">>> [3/6] 生成 my.cnf 配置..."
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local pool_size="1G"
    [[ "$mem_mb" -gt 4000 ]] && pool_size="$((mem_mb * 7 / 10 / 1024))G"

    cat > /etc/my.cnf <<EOF
[client]
port    = 3306
socket  = $DATA_DIR/mysql/tmp/mysql.sock

[mysql]
prompt="\u@db \R:\m:\s [\d]> "
default-character-set = utf8mb4

[mysqld]
user    = mysql
port    = 3306
basedir = $MYSQL_BASE
datadir = $DATA_DIR/mysql/data
socket  = $DATA_DIR/mysql/tmp/mysql.sock
pid-file = $DATA_DIR/mysql/tmp/mysql.pid
mysqlx = OFF

# 性能调优
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
skip_name_resolve = 1
innodb_buffer_pool_size = $pool_size
innodb_flush_method = O_DIRECT
innodb_log_buffer_size = 32M
log_timestamps = SYSTEM
max_connections = 1000

# 日志
log-error = $DATA_DIR/mysql/log/error.log
slow_query_log = ON
slow_query_log_file = $DATA_DIR/mysql/log/slow.log
long_query_time = 2
EOF
}

# --- 5. 初始化与启动 ---
setup_mysql() {
    echo ">>> [4/6] 初始化数据库..."
    chmod 777 $DATA_DIR/mysql/tmp
    
    # 再次检查依赖库是否生效
    if ! $MYSQL_BASE/bin/mysqld --version >/dev/null 2>&1; then
        echo "致命错误: 依赖库加载失败 (libaio/libncurses)，请检查系统库路径。"
        exit 1
    fi

    if [ ! -d "$DATA_DIR/mysql/data/mysql" ]; then
        $MYSQL_BASE/bin/mysqld --defaults-file=/etc/my.cnf --initialize --user=mysql
    fi

    TEMP_PASS=$(grep 'temporary password' $DATA_DIR/mysql/log/error.log | awk '{print $NF}')

    cat > /usr/lib/systemd/system/mysql.service <<EOF
[Unit]
Description=MySQL Server
After=network.target
[Service]
User=mysql
Group=mysql
ExecStart=$MYSQL_BASE/bin/mysqld --defaults-file=/etc/my.cnf
LimitNOFILE=65535
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mysql --now
    
    echo ">>> 等待服务启动 (15s)..."
    sleep 15

    echo ">>> [5/6] 正在配置安全密码..."
    $MYSQL_BASE/bin/mysql --connect-expired-password -uroot -p"$TEMP_PASS" <<SQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_MYSQL_PASS';
FLUSH PRIVILEGES;
SQL_EOF

    # 环境变量设置
    if ! grep -q "$MYSQL_BASE/bin" /etc/profile; then
        echo "export PATH=$MYSQL_BASE/bin:\$PATH" >> /etc/profile
        export PATH=$MYSQL_BASE/bin:$PATH
    fi
}

# --- 6. 日志轮替 ---
setup_logrotate() {
    echo ">>> [6/6] 配置日志轮替..."
    cat > /etc/logrotate.d/mysql <<EOF
$DATA_DIR/mysql/log/*.log {
    daily
    rotate 30
    missingok
    compress
    notifempty
    sharedscripts
    postrotate
        if [ -f $DATA_DIR/mysql/tmp/mysql.pid ]; then
            kill -HUP \$(cat $DATA_DIR/mysql/tmp/mysql.pid)
        fi
    endscript
}
EOF
}

# --- 执行 ---
main() {
    init_env
    download_mysql
    generate_cnf
    setup_mysql
    setup_logrotate
    
    echo "-------------------------------------------------------"
    echo "✅ MySQL 安装及深度优化完成！"
    echo "系统版本: $OS_ID $OS_VER"
    echo "MySQL版本: $REAL_VER"
    echo "Root 密码: $NEW_MYSQL_PASS"
    echo "请执行 'source /etc/profile' 让 mysql 命令生效"
    echo "-------------------------------------------------------"
}

main
