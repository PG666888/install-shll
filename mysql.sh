#!/bin/bash

# =================================================================
# 脚本名称: mysql_ultimate_compat.sh
# 兼容性: Ubuntu 20/22/24, RHEL/CentOS/Rocky/Alma 7/8/9
# 功能: 自动最新版、自动补全旧版库、RedHat 兼容优化
# =================================================================

set -e

# --- 1. 配置区 ---
NEW_MYSQL_PASS="MyNewPass@123" 
DATA_DIR="/data"
MYSQL_BASE="/usr/local/mysql"
USER_VER=$1  # 脚本第一个参数可指定版本号

# --- 2. 环境初始化 ---
init_env() {
    echo ">>> 正在检查系统环境..."
    if [[ "$EUID" -ne 0 ]]; then echo "错误: 请以 root 运行"; exit 1; fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VER=$VERSION_ID
    else
        echo "无法识别系统"; exit 1
    fi

    echo ">>> 正在为 $OS_ID $OS_VER 安装依赖..."

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        apt-get update -qq
        # 兼容 Ubuntu 24.04 的 libaio 命名
        apt-get install -y libaio1t64 2>/dev/null || apt-get install -y libaio1
        apt-get install -y wget curl gawk xz-utils logrotate libnuma1 >/dev/null
        
        # 针对新版 Ubuntu 缺失 libncurses5 的补丁
        if [[ "$OS_VER" > "23" ]]; then
            echo "正在安装 Ubuntu 24.04 兼容性库..."
            # 使用软连接让系统识别 libncurses5
            apt-get install -y libncurses6 libtinfo6 >/dev/null
            ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
            ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
        else
            apt-get install -y libncurses5 libtinfo5 >/dev/null
        fi

    elif [[ "$OS_ID" == "rhel" || "$OS_ID" == "centos" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        # RedHat 系依赖安装
        yum install -y epel-release >/dev/null
        yum install -y wget curl gawk xz libaio numactl bzip2 logrotate >/dev/null
        # RHEL 8/9 需要特殊的兼容库
        yum install -y ncurses-compat-libs 2>/dev/null || yum install -y ncurses-libs
    fi

    # 目录与用户创建
    mkdir -p $DATA_DIR/{software,mysql} $DATA_DIR/mysql/{data,log,tmp}
    if ! id mysql &>/dev/null; then
        useradd -M -s /sbin/nologin mysql
    fi
}

# --- 3. 动态获取版本与下载 ---
download_mysql() {
    cd $DATA_DIR/software/
    if [ -z "$USER_VER" ]; then
        echo ">>> 正在探测官网最新 8.0 版本..."
        REAL_VER=$(curl -s https://downloads.mysql.com/archives/community/ | grep -oE '8\.0\.[0-9]+' | head -1)
    else
        REAL_VER=$USER_VER
    fi

    # 统一使用 glibc2.17 架构包，兼容性最广
    PKG="mysql-${REAL_VER}-linux-glibc2.17-x86_64.tar.xz"
    URL="https://downloads.mysql.com/archives/get/p/23/file/${PKG}"

    if [ ! -f "$PKG" ]; then
        echo ">>> 正在下载 MySQL $REAL_VER..."
        wget --no-check-certificate -c "$URL"
    fi

    echo ">>> 正在安装至 $MYSQL_BASE ..."
    tar -xJf "$PKG"
    EXTRACTED_DIR=$(ls -d mysql-${REAL_VER}-*)
    [ -d "$MYSQL_BASE" ] && rm -rf "$MYSQL_BASE"
    mv "$EXTRACTED_DIR" "$MYSQL_BASE"
    
    chown -R mysql:mysql "$MYSQL_BASE" "$DATA_DIR/mysql"
}

# --- 4. 配置文件生成 ---
generate_cnf() {
    echo ">>> 生成 my.cnf ..."
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

# 字符集与性能
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
skip_name_resolve = 1
innodb_buffer_pool_size = $pool_size
innodb_flush_method = O_DIRECT
innodb_log_buffer_size = 32M
max_connections = 1000

# 日志
log-error = $DATA_DIR/mysql/log/error.log
slow_query_log = ON
slow_query_log_file = $DATA_DIR/mysql/log/slow.log
long_query_time = 2
EOF
}

# --- 5. 初始化与服务管理 ---
setup_mysql() {
    echo ">>> 正在初始化 MySQL (由于是最新版，可能较慢)..."
    chmod 777 $DATA_DIR/mysql/tmp
    $MYSQL_BASE/bin/mysqld --defaults-file=/etc/my.cnf --initialize --user=mysql

    TEMP_PASS=$(grep 'temporary password' $DATA_DIR/mysql/log/error.log | awk '{print $NF}')

    # 写入 systemd
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
    sleep 10 # 增加等待时间确保服务启动完毕

    echo ">>> 执行安全配置..."
    $MYSQL_BASE/bin/mysql --connect-expired-password -uroot -p"$TEMP_PASS" <<SQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_MYSQL_PASS';
FLUSH PRIVILEGES;
SQL_EOF

    # 环境变量
    if ! grep -q "$MYSQL_BASE/bin" /etc/profile; then
        echo "export PATH=$MYSQL_BASE/bin:\$PATH" >> /etc/profile
    fi
}

# --- 6. 日志切分 (Logrotate) ---
setup_logrotate() {
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

# --- 主程序 ---
main() {
    init_env
    download_mysql
    generate_cnf
    setup_mysql
    setup_logrotate
    
    echo "-------------------------------------------------------"
    echo "✅ 安装完成！系统已识别为: $OS_ID"
    echo "MySQL 版本: $REAL_VER"
    echo "管理员密码: $NEW_MYSQL_PASS"
    echo "请执行: source /etc/profile"
    echo "-------------------------------------------------------"
}

main
