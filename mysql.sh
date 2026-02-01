#!/bin/bash

# =================================================================
# 脚本名称: mysql_ultimate_optimized_v2.sh
# 功能: 自动版本、库依赖补全、安全加固、日志轮替、性能调优
# =================================================================

set -e # 遇到错误立即退出

# --- 1. 全局配置区 ---
NEW_MYSQL_PASS="MyNewPass@123" 
DATA_DIR="/data"
MYSQL_BASE="/usr/local/mysql"
# 建议使用更加通用的版本，或者根据架构选择
FALLBACK_VER="8.0.33"

# --- 2. 基础环境检查 ---
check_env() {
    if [ "$EUID" -ne 0 ]; then echo "请以 root 运行"; exit 1; fi
    if grep -qs "ubuntu" /etc/os-release; then
        OS="ubuntu"
    elif grep -qs "centos\|rhel\|rocky\|almalinux" /etc/os-release; then
        OS="centos"
    else
        echo "暂不支持该系统"; exit 1
    fi
    echo "系统识别成功: $OS"
}

# --- 3. 系统初始化与依赖补全 ---
init_system() {
    echo "正在配置系统优化项与依赖库..."
    
    if [ "$OS" == "ubuntu" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        # 关键：Ubuntu 20.04+ 必须手动装 libncurses5 和 libaio1
        apt-get install -y curl wget awk grep libaio1 libnuma1 xz-utils libncurses5 libtinfo5 logrotate
    else
        yum install -y epel-release
        yum install -y curl wget awk grep libaio numactl xz perl-Data-Dumper perl-devel libaio-devel logrotate ncurses-compat-libs
    fi

    # 提升文件句柄数
    if ! grep -q "soft nproc 65535" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<EOF
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
EOF
    fi
}

# --- 4. 磁盘挂载 (带检查逻辑) ---
mount_data_disk() {
    echo "--- 磁盘检查 ---"
    lsblk
    read -p "请输入要挂载到 $DATA_DIR 的设备名 (如 /dev/vdb, 已挂载请回车跳过): " disk
    if [ ! -z "$disk" ]; then
        if [ -b "$disk" ]; then
            mkdir -p $DATA_DIR
            # 如果没有文件系统则格式化为 xfs (生产环境推荐)
            if ! blkid "$disk" | grep -q "TYPE"; then
                mkfs.xfs "$disk"
            fi
            local uuid=$(blkid -s UUID -o value "$disk")
            echo "UUID=$uuid $DATA_DIR xfs defaults 0 0" >> /etc/fstab
            mount -a && echo "磁盘 $disk 挂载成功"
        else
            echo "警告: 设备 $disk 不存在，跳过挂载。"
        fi
    fi
}

# --- 5. 下载并解压 ---
download_mysql() {
    # 自动获取最新 8.0 系列版本号
    local ver=$(curl -s https://downloads.mysql.com/archives/community/ | grep -oE '8\.0\.[0-9]+' | head -1)
    REAL_VER=${ver:-$FALLBACK_VER}
    
    # 优先匹配 glibc2.17 (更适合现代系统)
    local pkg="mysql-$REAL_VER-linux-glibc2.17-x86_64.tar.xz"
    
    mkdir -p $DATA_DIR/{software,mysql} $DATA_DIR/mysql/{data,log,tmp}
    id mysql &>/dev/null || useradd -M -s /sbin/nologin mysql
    
    cd $DATA_DIR/software/
    if [ ! -f "$pkg" ]; then
        echo "正在下载 MySQL $REAL_VER..."
        wget -c "https://downloads.mysql.com/archives/get/p/23/file/$pkg"
    fi
    
    echo "正在解压..."
    tar -xJf "$pkg" 
    local extracted_dir=$(ls -d mysql-$REAL_VER-*)
    [ -d "$MYSQL_BASE" ] && rm -rf "$MYSQL_BASE"
    mv "$extracted_dir" "$MYSQL_BASE"
    
    # 权限预设
    chown -R mysql:mysql "$MYSQL_BASE"
    chown -R mysql:mysql "$DATA_DIR/mysql"
    chmod 750 $DATA_DIR/mysql/data
    chmod 777 $DATA_DIR/mysql/tmp
}

# --- 6. 生成 my.cnf ---
generate_cnf() {
    echo "生成配置文件..."
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    # 动态计算内存：如果是 4G 以上，取 70% 给缓冲池
    local pool_size="1G"
    if [ "$mem_mb" -gt 4096 ]; then
        pool_size="$((mem_mb * 7 / 10 / 1024))G"
    fi

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

# --- 字符集与规范 ---
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
skip_name_resolve = 1
log_timestamps = SYSTEM

# --- 内存与性能 ---
innodb_buffer_pool_size = $pool_size
innodb_buffer_pool_instances = 8
innodb_log_buffer_size = 32M
innodb_flush_method = O_DIRECT
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# --- 连接数 ---
max_connections = 1000
max_connect_errors = 100000
wait_timeout = 600
interactive_timeout = 600

# --- 日志 ---
log-error = $DATA_DIR/mysql/log/error.log
slow_query_log = ON
slow_query_log_file = $DATA_DIR/mysql/log/slow.log
long_query_time = 2
binlog_expire_logs_seconds = 604800
EOF
}

# --- 7. 初始化与 Systemd 服务 ---
setup_service() {
    echo "初始化数据库 (请耐心等待)..."
    $MYSQL_BASE/bin/mysqld --defaults-file=/etc/my.cnf --initialize --user=mysql
    
    # 提取临时密码
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
    sleep 5
}

# --- 8. 安全配置 (非交互式) ---
secure_mysql() {
    echo "执行安全加固..."
    # 修改 root 密码
    $MYSQL_BASE/bin/mysql --connect-expired-password -uroot -p"$TEMP_PASS" <<SQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW_MYSQL_PASS';
-- 如果确实需要远程访问，请在安装后手动开启特定 IP，此处默认仅限 localhost 以保安全
-- CREATE USER 'root'@'%' IDENTIFIED BY '$NEW_MYSQL_PASS';
-- GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL_EOF

    # 配置环境变量
    if ! grep -q "$MYSQL_BASE" /etc/profile; then
        echo "export PATH=$MYSQL_BASE/bin:\$PATH" >> /etc/profile
        export PATH=$MYSQL_BASE/bin:$PATH
    fi
}

# --- 9. 配置日志切分 ---
setup_logrotate() {
    echo "配置日志轮替策略..."
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
        if [ -f $DATA_DIR/mysql/tmp/mysql.pid ]; then
            kill -HUP \$(cat $DATA_DIR/mysql/tmp/mysql.pid)
        fi
    endscript
}
EOF
}

# --- 主函数 ---
main() {
    check_env
    init_system
    mount_data_disk
    download_mysql
    generate_cnf
    setup_service
    secure_mysql
    setup_logrotate
    
    echo "-------------------------------------------------------"
    echo "✅ MySQL 安装成功！"
    echo "版本: $REAL_VER"
    echo "数据目录: $DATA_DIR/mysql/data"
    echo "Root 密码: $NEW_MYSQL_PASS"
    echo "提示: 环境变量已更新，请运行 'source /etc/profile' 生效"
    echo "-------------------------------------------------------"
}

main
