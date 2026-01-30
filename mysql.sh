#!/bin/bash

# =================================================================
# 脚本名称: mysql_ultimate_optimized.sh
# 功能: 自动版本、磁盘挂载、utf8mb4 优化、日志切分、安全加固
# =================================================================

# --- 1. 全局配置区 ---
NEW_MYSQL_PASS="MyNewPass@123" 
DATA_DIR="/data"
MYSQL_BASE="/usr/local/mysql"
FALLBACK_VER="8.0.24"

# --- 2. 基础环境检查 ---
check_env() {
    if [ "$EUID" -ne 0 ]; then echo "请以 root 运行"; exit 1; fi
    if grep -qs "ubuntu" /etc/os-release; then
        OS="ubuntu"
    elif grep -qs "centos\|rhel" /etc/os-release; then
        OS="centos"
    else
        echo "暂不支持该系统"; exit 1
    fi
    echo "系统识别成功: $OS"
}

# --- 3. 系统初始化 ---
init_system() {
    echo "正在配置系统优化项..."
    hostnamectl set-hostname mysql-1
    
    if [ "$OS" == "ubuntu" ]; then
        ufw disable &>/dev/null
        systemctl stop apparmor &>/dev/null && systemctl disable apparmor &>/dev/null
        apt-get update -y && apt-get install -y curl wget awk grep libaio1 libnuma1 xz-utils libncurses5 logrotate
    else
        systemctl disable firewalld --now &>/dev/null
        sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/sysconfig/selinux
        setenforce 0 || true
        yum install -y curl wget awk grep libaio numactl xz perl-Data-Dumper perl-devel libaio-devel logrotate
    fi

    if ! grep -q "soft nproc 65535" /etc/security/limits.conf; then
        echo -e "* soft nproc 65535\n* hard nproc 65535\n* soft nofile 65535\n* hard nofile 65535\n" >> /etc/security/limits.conf
    fi
}

# --- 4. 磁盘挂载 (不格式化) ---
mount_data_disk() {
    lsblk
    read -p "请输入要挂载到 $DATA_DIR 的设备名 (如 /dev/vdb, 已挂载请回车): " disk
    if [ ! -z "$disk" ] && [ -b "$disk" ]; then
        mkdir -p $DATA_DIR
        if ! grep -q "$DATA_DIR" /etc/fstab; then
            local uuid=$(blkid -s UUID -o value "$disk")
            local type=$(blkid -s TYPE -o value "$disk")
            echo "UUID=$uuid $DATA_DIR $type defaults 0 0" >> /etc/fstab
            mount -a && echo "磁盘 $disk 挂载成功"
        fi
    fi
}

# --- 5. 下载并解压 ---
download_mysql() {
    local ver=$(curl -s --connect-timeout 5 https://downloads.mysql.com/archives/community/ | grep -oE '8\.0\.[0-9]+' | head -1)
    REAL_VER=${ver:-$FALLBACK_VER}
    local pkg="mysql-$REAL_VER-linux-glibc2.12-x86_64.tar.xz"
    
    mkdir -p $DATA_DIR/{software,mysql} $DATA_DIR/mysql/{data,log,tmp}
    id mysql &>/dev/null || useradd -M -s /sbin/nologin mysql
    
    cd $DATA_DIR/software/
    [ ! -f "$pkg" ] && wget -c "https://downloads.mysql.com/archives/get/p/23/file/$pkg"
    
    tar -xvf "$pkg" &>/dev/null
    local extracted_dir=$(ls -d mysql-$REAL_VER-*)
    [ -d "$MYSQL_BASE" ] && rm -rf "$MYSQL_BASE"
    mv "$extracted_dir" "$MYSQL_BASE"
    chown -R mysql:mysql "$MYSQL_BASE" "$DATA_DIR/mysql"
}

# --- 6. 生成 my.cnf (升级至 utf8mb4) ---
generate_cnf() {
    echo "生成配置文件 (字符集: utf8mb4)..."
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local pool_size="1G"
    [ "$mem_mb" -gt 4096 ] && pool_size="$((mem_mb * 7 / 10 / 1024))G"

    cat > /etc/my.cnf <<EOF
[client]
port    = 3306
socket  = $DATA_DIR/mysql/tmp/mysql.sock

[mysql]
prompt="\u@db \R:\m:\s [\d]> "
no-auto-rehash
default-character-set = utf8mb4

[mysqld]
user    = mysql
port    = 3306
basedir = $MYSQL_BASE
datadir = $DATA_DIR/mysql/data
socket  = $DATA_DIR/mysql/tmp/mysql.sock
pid-file = $DATA_DIR/mysql/tmp/mysql.pid

# --- 字符集优化 ---
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
skip_name_resolve = 1
event_scheduler = on
sql_mode = 'NO_UNSIGNED_SUBTRACTION,NO_ENGINE_SUBSTITUTION'

# --- 性能优化项 ---
open_files_limit = 65535
innodb_open_files = 65535 
back_log = 1024
max_connections = 512 
max_connect_errors = 1000000 
interactive_timeout = 300 
wait_timeout = 300 
max_allowed_packet = 1024M
table_open_cache = 2048 
table_open_cache_instances = 32
thread_cache_size = 128 

# --- 内存调优 ---
innodb_buffer_pool_size = $pool_size
innodb_buffer_pool_instances = 16
innodb_log_buffer_size = 32M 
innodb_flush_method = O_DIRECT 

# --- 日志配置 ---
log-error = $DATA_DIR/mysql/log/error.log 
slow_query_log = ON 
slow_query_log_file = $DATA_DIR/mysql/log/slow_mysql.log 
long_query_time = 2

# --- 复制与 Binlog ---
server-id = $((RANDOM%1000 + 3306))
log-bin = $DATA_DIR/mysql/log/binlog-mysql
binlog_format = row 
binlog_expire_logs_seconds = 2592000
EOF
}

# --- 7. 【新增】配置日志切分 (Logrotate) ---
setup_logrotate() {
    echo "配置日志切分策略..."
    cat > /etc/logrotate.d/mysql <<EOF
$DATA_DIR/mysql/log/*.log {
    daily
    rotate 30
    missingok
    compress
    dateext
    notifempty
    sharedscripts
    postrotate
        # 这里的脚本会通知 MySQL 重新打开日志文件，实现平滑切分
        if [ -f $DATA_DIR/mysql/tmp/mysql.pid ]; then
            kill -HUP \$(cat $DATA_DIR/mysql/tmp/mysql.pid)
        fi
    endscript
}
EOF
    # 赋予正确权限并测试一次
    chmod 644 /etc/logrotate.d/mysql
    logrotate -f /etc/logrotate.d/mysql &>/dev/null
    echo "日志切分配置完成，保留30天历史记录。"
}

# --- 8. 初始化与安全设置 ---
setup_service_and_secure() {
    rm -rf $DATA_DIR/mysql/data/*
    $MYSQL_BASE/bin/mysqld --defaults-file=/etc/my.cnf --initialize --user=mysql
    local temp_pass=$(grep 'temporary password' $DATA_DIR/mysql/log/error.log | awk '{print $NF}')

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
Type=simple
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable mysql && systemctl start mysql
    sleep 10

    $MYSQL_BASE/bin/mysql --connect-expired-password -uroot -p"$temp_pass" <<SQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_MYSQL_PASS';
CREATE USER 'root'@'%' IDENTIFIED BY '$NEW_MYSQL_PASS';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL_EOF
    
    [ ! -f /usr/bin/mysql ] && ln -s $MYSQL_BASE/bin/mysql /usr/bin/mysql
    echo "export PATH=$MYSQL_BASE/bin:\$PATH" >> /etc/profile
}

# --- 执行流 ---
main() {
    check_env
    init_system
    mount_data_disk
    download_mysql
    generate_cnf
    setup_logrotate
    setup_service_and_secure
    
    echo "-------------------------------------------------------"
    echo "✅ MySQL 安装及深度优化完成！"
    echo "字符集: utf8mb4 | 日志切分: 已开启 (30天保留)"
    echo "数据库密码: $NEW_MYSQL_PASS"
    echo "-------------------------------------------------------"
}

main
