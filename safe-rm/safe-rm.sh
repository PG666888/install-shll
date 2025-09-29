#!/usr/bin/env bash
#
# safe-rm 完整管理脚本 (回收站保留目录结构 + sudo 用户日志 + 交互式恢复)
#

set -e

SAFE_RM_PATH="/usr/local/bin/rm"   # 覆盖 PATH 中 rm
REAL_RM="/bin/rm"                   # 系统原 rm
LOG_FILE="/var/log/safe-rm.log"
LOGROTATE_FILE="/etc/logrotate.d/safe-rm"
CRON_CMD="$SAFE_RM_PATH --clean"

log_action() {
    user=${SUDO_USER:-$(whoami)}
    echo "$(date +"%Y-%m-%d %H:%M:%S") | user=$user | action=$1 | file=$2" >> "$LOG_FILE"
}

install_safe_rm() {
    echo "[INFO] 安装 safe-rm 到 $SAFE_RM_PATH ..."

    sudo tee "$SAFE_RM_PATH" > /dev/null <<"EOF"
#!/usr/bin/env bash
TRASH_DIR="$HOME/.trash"
REAL_RM="/bin/rm"
LOG_FILE="/var/log/safe-rm.log"

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
get_user() { [[ -n "$SUDO_USER" ]] && echo "$SUDO_USER" || whoami; }
log_action() { echo "$(timestamp) | user=$(get_user) | action=$1 | file=$2" >> "$LOG_FILE"; }

usage() {
    cat <<USAGE
用法: rm [选项] 文件...
  默认      移动到 \$TRASH_DIR (保留目录结构)
  --purge   真删除 (调用 \$REAL_RM)
  --clean   清理回收站中 7 天以上的文件
  restore   交互式恢复回收站文件
USAGE
    exit 1
}

[[ $# -eq 0 ]] && usage

restore_trash_interactive() {
    files=($(find "$TRASH_DIR" -type f | sort))
    count=${#files[@]}

    if [[ $count -eq 0 ]]; then
        echo "[INFO] 回收站为空"
        return
    fi

    echo "[INFO] 回收站文件列表:"
    for i in "${!files[@]}"; do
        echo "[$i] ${files[$i]#$TRASH_DIR/}"
    done

    echo "恢复选项："
    echo "  输入索引(空格分隔)恢复单个或多个文件"
    echo "  输入 'all' 恢复全部文件"
    echo "  输入 'keyword:<关键字>' 按文件名关键字恢复"
    echo "  输入 'dir:<目录路径>' 恢复某个目录下所有文件"

    read -r selection

    selected_files=()
    if [[ "$selection" == "all" ]]; then
        selected_files=("${files[@]}")
    elif [[ "$selection" == keyword:* ]]; then
        key="${selection#keyword:}"
        for f in "${files[@]}"; do
            [[ "$(basename "$f")" == *"$key"* ]] && selected_files+=("$f")
        done
    elif [[ "$selection" == dir:* ]]; then
        dir_path="${selection#dir:}"
        dir_path="$(realpath "$dir_path")"
        for f in "${files[@]}"; do
            [[ "$f" == "$TRASH_DIR$dir_path"* ]] && selected_files+=("$f")
        done
    else
        indices=($selection)
        for idx in "${indices[@]}"; do
            [[ -n "${files[$idx]}" ]] && selected_files+=("${files[$idx]}")
        done
    fi

    if [[ ${#selected_files[@]} -eq 0 ]]; then
        echo "[INFO] 没有匹配的文件可恢复"
        return
    fi

    for file in "${selected_files[@]}"; do
        orig_path="${file#$TRASH_DIR}"
        orig_dir="$(dirname "$orig_path")"
        mkdir -p "$orig_dir"

        if [[ -e "$orig_path" ]]; then
            base="$(basename "$orig_path")"
            ext="${base##*.}"
            name="${base%.*}"
            new_path="$orig_dir/${name}_restored_$(date +%s).${ext}"
            echo "[WARN] $orig_path 已存在, 恢复为 $new_path"
            mv "$file" "$new_path"
            log_action "RESTORE_RENAME" "$new_path"
        else
            mv "$file" "$orig_path"
            log_action "RESTORE" "$orig_path"
            echo "[INFO] 已恢复: $orig_path"
        fi
    done

    find "$TRASH_DIR" -type d -empty -delete
    echo "[SUCCESS] 恢复完成。"
}

case "$1" in
    --purge)
        shift
        "$REAL_RM" "$@"
        for f in "$@"; do log_action "PURGE" "$f"; done
        exit 0
        ;;
    --clean)
        echo "[INFO] 清理 $TRASH_DIR 中 7 天以上的文件..."
        find "$TRASH_DIR" -type f -mtime +7 | while read -r file; do
            "$REAL_RM" -f "$file"
            echo "$(timestamp) | user=$(get_user) | CLEAN | $file -> DELETED" >> "$LOG_FILE"
        done
        find "$TRASH_DIR" -type d -empty -delete
        exit 0
        ;;
    restore)
        restore_trash_interactive
        exit 0
        ;;
esac

for target in "$@"; do
    if [[ -e "$target" ]]; then
        abs_path="$(realpath "$target")"
        trash_target="$TRASH_DIR$abs_path"
        mkdir -p "$(dirname "$trash_target")"
        mv --backup=numbered "$target" "$trash_target"
        echo "[INFO] 已移动: $target -> $trash_target"
        log_action "TRASH" "$target"
    else
        echo "[INFO] 文件不存在: $target"
        log_action "MISS" "$target"
    fi
done
EOF

    sudo chmod +x "$SAFE_RM_PATH"

    echo "[INFO] 确保 PATH 优先使用 /usr/local/bin ..."
    if ! grep -q "/usr/local/bin" <<< "$PATH"; then
        echo "export PATH=/usr/local/bin:\$PATH" >> "$HOME/.bashrc"
        echo "[INFO] 已将 /usr/local/bin 添加到 PATH 前面，请重新登录生效"
    fi

    echo "[INFO] 创建日志文件并设置权限..."
    sudo touch "$LOG_FILE"
    sudo chown root:root "$LOG_FILE"
    sudo chmod 644 "$LOG_FILE"

    echo "[INFO] 配置 cron 定时清理..."
    (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 3 * * * $CRON_CMD") | crontab -

    echo "[INFO] 配置 logrotate ..."
    sudo tee "$LOGROTATE_FILE" > /dev/null <<EOF
$LOG_FILE {
    daily
    rotate 7
    size 10M
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

    echo "[SUCCESS] 安装完成！rm 默认进入 safe-rm 回收站，保留目录结构。"
    echo "[INFO] 使用 '--purge' 真删除: rm --purge <file>"
    echo "[INFO] 使用 'restore' 交互式恢复文件: rm restore"
    echo "[INFO] 日志文件: $LOG_FILE"
}

uninstall_safe_rm() {
    echo "[INFO] 卸载 safe-rm ..."
    [[ -f "$SAFE_RM_PATH" ]] && sudo rm -f "$SAFE_RM_PATH" && echo "[INFO] 已删除 $SAFE_RM_PATH"
    [[ -f "$LOGROTATE_FILE" ]] && sudo rm -f "$LOGROTATE_FILE" && echo "[INFO] 删除 logrotate 配置"
    crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab - || true
    echo "[SUCCESS] safe-rm 已卸载完成。"
}

clean_trash() {
    echo "[INFO] 手动清理 $HOME/.trash 中 7 天以上的文件..."
    find "$HOME/.trash" -type f -mtime +7 | while read -r file; do
        /bin/rm -f "$file"
        user=${SUDO_USER:-$(whoami)}
        echo "$(date +"%Y-%m-%d %H:%M:%S") | user=$user | CLEAN | $file -> DELETED" >> "$LOG_FILE"
    done
    find "$HOME/.trash" -type d -empty -delete
    echo "[SUCCESS] 清理完成。"
}

case "$1" in
    install)
        install_safe_rm
        ;;
    uninstall)
        uninstall_safe_rm
        ;;
    clean)
        clean_trash
        ;;
    restore)
        "$SAFE_RM_PATH" restore
        ;;
    *)
        echo "用法: $0 {install|uninstall|clean|restore}"
        exit 1
        ;;
esac
