#!/bin/bash
  
#'''''''''''''''''''''
# 颜色设置
SETCOLOR_SUCCESS="echo -en \\033[1;32m"
SETCOLOR_FAILURE="echo -en \\033[1;31m"
SETCOLOR_WARNING="echo -en \\033[1;33m"
SETCOLOR_NORMAL="echo -en \\033[0;39m"
UNSET_COLOR='\E[0m'
  
# 检查ufw是否安装
check_ufw_installed() {
    if ! command -v ufw &> /dev/null; then
        $SETCOLOR_FAILURE
        echo "错误：ufw 未安装，请先运行 'sudo apt install ufw'"
        $SETCOLOR_NORMAL
        exit 1
    fi
}
  
# 检查at是否安装
check_at_installed() {
    if ! command -v at &> /dev/null; then
        $SETCOLOR_FAILURE
        echo "错误：at 未安装，请运行 'sudo apt install at' 安装该工具。"
        $SETCOLOR_NORMAL
        exit 1
    fi
}
  
# 检查ufw是否激活
check_ufw_active() {
    status=$(sudo ufw status | awk '/Status:/ {print $2}')
    if [ "$status" != "active" ]; then
        $SETCOLOR_WARNING
        echo "警告：ufw 未激活！"
        $SETCOLOR_NORMAL
  
        read -p "是否要启用ufw防火墙？(y/n): " activate_choice
        if [[ $activate_choice =~ ^[Yy]$ ]]; then
            echo "正在启用ufw防火墙..."
            echo "y" | sudo ufw enable
            if [[ $? -ne 0 ]]; then
                $SETCOLOR_FAILURE
                echo "错误：启用 ufw 失败！"
                $SETCOLOR_NORMAL
                exit 1
            fi
            $SETCOLOR_SUCCESS
            echo "ufw 已成功启用"
            $SETCOLOR_NORMAL
            return 0
        else
            $SETCOLOR_WARNING
            echo "警告：ufw 未启用，防火墙功能可能无法正常工作！"
            $SETCOLOR_NORMAL
            return 1
        fi
    fi
    return 0
}
  
# 检查 /var/backups/ufw 目录权限
check_backup_permissions() {
    if [[ ! -w "/var/backups/ufw" ]]; then
        $SETCOLOR_FAILURE
        echo "错误：没有权限写入备份目录！"
        $SETCOLOR_NORMAL
        exit 1
    fi
}
  
# 菜单显示
menu() {
    echo -e "\n"
    echo "******************* UFW 防火墙管理 *******************"
    echo "请从以下选项中进行选择:"
    echo " 1. 禁止 PING"
    echo " 2. 允许 PING"
    echo " 3. 开放指定端口（支持协议选择）"
    echo " 4. 关闭指定端口（支持协议选择）"
    echo " 5. 允许指定IP访问指定端口"
    echo " 6. 取消指定IP访问指定端口"
    echo " 7. 允许指定IP访问所有端口"
    echo " 8. 取消指定IP访问所有端口"
    echo " 9. 列出所有防火墙规则"
    echo "10. 查看防火墙状态"
    echo "11. 启用/关闭 UFW 日志记录"
    echo "12. 一键重置防火墙规则（谨慎）"
    echo "13. 导出当前规则到文件"
    echo "14. 从文件导入规则（仅限 allow/deny）"
    echo "15. 设置默认防火墙策略（入站/出站）"
    echo "16. 手动备份当前规则到 /var/backups/ufw/"
    echo "17. 设置定时放行端口（基于 at 命令）"
    echo "19. 退出"
    echo "******************************************************"
    echo -e "\n"
}
  
# 管理 ICMP
manage_ping() {
    case $1 in
        block)
            $SETCOLOR_WARNING
            echo "禁止 PING（设置 icmp_echo_ignore_all=1 并持久化）"
            $SETCOLOR_NORMAL
            sudo sysctl -w net.ipv4.icmp_echo_ignore_all=1
            sudo sed -i '/^net.ipv4.icmp_echo_ignore_all/d' /etc/sysctl.conf
            echo "net.ipv4.icmp_echo_ignore_all = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl -p > /dev/null
            ;;
        allow)
            $SETCOLOR_WARNING
            echo "允许 PING（设置 icmp_echo_ignore_all=0 并持久化）"
            $SETCOLOR_NORMAL
            sudo sysctl -w net.ipv4.icmp_echo_ignore_all=0
            sudo sed -i '/^net.ipv4.icmp_echo_ignore_all/d' /etc/sysctl.conf
            echo "net.ipv4.icmp_echo_ignore_all = 0" | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl -p > /dev/null
            ;;
    esac
  
    echo "当前 PING 状态:"
    sysctl net.ipv4.icmp_echo_ignore_all
}
  
# 管理端口
manage_port() {
    case $1 in
        open)
            $SETCOLOR_WARNING
            echo "执行: sudo ufw allow $2/$3"
            $SETCOLOR_NORMAL
            sudo ufw allow "$2/$3"
            ;;
        close)
            $SETCOLOR_WARNING
            echo "执行: sudo ufw delete allow $2/$3"
            $SETCOLOR_NORMAL
            sudo ufw delete allow "$2/$3" || true
            ;;
    esac
}
  
  
  
  
# 默认策略设置
set_default_policy() {
    echo "当前默认策略："
    sudo ufw status verbose | grep "Default:"
    echo "示例：deny（拒绝） 或 allow（允许）"
    read -p "设置默认入站策略（deny/allow）: " in_policy
    read -p "设置默认出站策略（deny/allow）: " out_policy
  
    if [[ "$in_policy" =~ ^(deny|allow)$ ]] && [[ "$out_policy" =~ ^(deny|allow)$ ]]; then
        sudo ufw default "$in_policy" incoming
        sudo ufw default "$out_policy" outgoing
        echo "默认策略设置完成：入站 $in_policy，出站 $out_policy"
    else
        $SETCOLOR_FAILURE
        echo "输入无效，仅允许 deny 或 allow"
        $SETCOLOR_NORMAL
    fi
}
  
# 备份当前规则
backup_rules() {
    check_backup_permissions
    backup_dir="/var/backups/ufw"
    sudo mkdir -p "$backup_dir"
    backup_file="$backup_dir/ufw-$(date +%Y%m%d).txt"
    sudo ufw status verbose > "$backup_file"
    echo "规则已备份到: $backup_file"
}
  
# 设置定时放行端口
schedule_temp_port() {
    check_at_installed
    read -p "要临时开放的端口号: " temp_port
    read -p "协议（tcp/udp，默认tcp）: " protocol
    protocol=${protocol:-tcp}
    read -p "放行持续时间（分钟）: " minutes
  
    sudo ufw allow "$temp_port/$protocol"
    echo "端口 $temp_port/$protocol 已开放，将于 $minutes 分钟后自动关闭"
  
    echo "sudo ufw delete allow $temp_port/$protocol" | at now + "$minutes" minutes
}
  
# 防火墙规则配置
apply_firewall_settings() {
    # 设置默认策略
    sudo ufw default deny incoming
    sudo ufw default deny outgoing
  
    # 重新加载规则
    sudo ufw reload
}
  
# 主程序
main() {
    check_ufw_installed
    check_at_installed
    check_ufw_active
  
    # 应用防火墙设置（设置默认策略）
    #apply_firewall_settings
  
    while true; do
        menu
        read -p "请输入数字选择菜单项：" choice
  
        if [[ $choice =~ ^[1-8]$ ]]; then
            if ! check_ufw_active; then
                $SETCOLOR_WARNING
                echo "操作已取消，因为ufw未激活"
                $SETCOLOR_NORMAL
                continue
            fi
        fi
  
        case $choice in
            1) manage_ping block ;;
            2) manage_ping allow ;;
            3)
                echo "示例：端口 80，协议 tcp"
                read -p "请输入要开放的端口号: " port
                if ! [[ "$port" =~ ^[0-9]+$ ]]; then
                    $SETCOLOR_FAILURE; echo "错误：请输入合法的端口号"; $SETCOLOR_NORMAL; continue
                fi
                read -p "请输入协议 (tcp/udp，默认tcp): " protocol
                [[ "$protocol" != "udp" ]] && protocol="tcp"
                manage_port open "$port" "$protocol"
                ;;
            4)
                echo "示例：端口 80，协议 tcp"
                read -p "请输入要关闭的端口号: " port
                if ! [[ "$port" =~ ^[0-9]+$ ]]; then
                    $SETCOLOR_FAILURE; echo "错误：请输入合法的端口号"; $SETCOLOR_NORMAL; continue
                fi
                read -p "请输入协议 (tcp/udp，默认tcp): " protocol
                [[ "$protocol" != "udp" ]] && protocol="tcp"
                manage_port close "$port" "$protocol"
                ;;
            5)
                read -p "请输入允许的IP地址: " ip
                read -p "请输入端口号: " port
                read -p "请输入协议 (tcp/udp，默认tcp): " protocol
                [[ "$protocol" != "udp" ]] && protocol="tcp"
                manage_ip_port allow "$ip" "$port" "$protocol"
                ;;
            6)
                read -p "请输入要禁止的IP地址: " ip
                read -p "请输入端口号: " port
                read -p "请输入协议 (tcp/udp，默认tcp): " protocol
                [[ "$protocol" != "udp" ]] && protocol="tcp"
                manage_ip_port deny "$ip" "$port" "$protocol"
                ;;
            7)
                read -p "请输入允许的IP地址: " ip
                manage_ip allow "$ip"
                ;;
            8)
                read -p "请输入要禁止的IP地址: " ip
                manage_ip deny "$ip"
                ;;
            9)
                $SETCOLOR_WARNING; echo "当前防火墙规则:"; $SETCOLOR_NORMAL
                sudo ufw status numbered
                ;;
            10)
                $SETCOLOR_WARNING; echo "防火墙状态:"; $SETCOLOR_NORMAL
                sudo ufw status verbose
                ;;
            11)
                echo "当前日志状态："
                sudo ufw status verbose | grep "Logging"
                read -p "是否启用日志记录？(y/n): " log_choice
                if [[ $log_choice =~ ^[Yy]$ ]]; then
                    sudo ufw logging on
                    echo "日志记录已启用"
                else
                    sudo ufw logging off
                    echo "日志记录已关闭"
                fi
                ;;
            12)
                $SETCOLOR_WARNING
                echo "警告：此操作将清除所有规则，恢复默认防火墙状态！"
                $SETCOLOR_NORMAL
                read -p "确定要继续吗？(yes/no): " confirm_reset
                if [[ "$confirm_reset" == "yes" ]]; then
                    sudo ufw --force reset
                    echo "所有规则已重置，请重新配置防火墙规则。"
                else
                    echo "已取消操作。"
                fi
                ;;
            13)
                backup_rules
                ;;
            14)
                read -p "请输入规则文件路径: " import_file
                if [[ ! -f "$import_file" ]]; then
                    $SETCOLOR_FAILURE; echo "错误：文件不存在！"; $SETCOLOR_NORMAL
                else
                    echo "导入规则中..."
                    while read -r line; do
                        [[ "$line" =~ ^(allow|deny|reject|limit) ]] && echo "执行: ufw $line" && sudo ufw $line
                    done < "$import_file"
                    echo "导入完成。"
                fi
                ;;
            15)
                set_default_policy
                ;;
            16)
                backup_rules
                ;;
            17)
                schedule_temp_port
                ;;
            18)
                $SETCOLOR_SUCCESS
                echo "感谢使用，再见！"
                $SETCOLOR_NORMAL
                exit 0
                ;;
            *)
                $SETCOLOR_FAILURE
                echo "无效选项，请重新输入"
                $SETCOLOR_NORMAL
                ;;
        esac
        echo -e "\n"
    done
}
  
main