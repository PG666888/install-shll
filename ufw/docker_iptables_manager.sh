#!/bin/bash

# 颜色设置
SETCOLOR_SUCCESS="echo -en \033[1;32m"
SETCOLOR_FAILURE="echo -en \033[1;31m"
SETCOLOR_WARNING="echo -en \033[1;33m"
SETCOLOR_NORMAL="echo -en \033[0;39m"
UNSET_COLOR='\E[0m'

# 检查 iptables 和 fzf 是否可用
check_dependencies() {
    for cmd in iptables fzf; do
        if ! command -v $cmd &>/dev/null; then
            $SETCOLOR_FAILURE
            echo "错误：缺少依赖 $cmd，请先手动安装！"
            $SETCOLOR_NORMAL
            exit 1
        fi
    done
}

# 获取宿主机 IP
get_host_ips() {
    ip addr show | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d/ -f1
}

# 获取所有 Docker 网络 CIDR
get_docker_cidrs() {
    docker network inspect $(docker network ls -q) 2>/dev/null |
        grep -Po '"Subnet":\s*"\K[0-9./]+' | sort -u
}

# 获取所有容器名称
get_containers() {
    docker ps --format '{{.Names}}'
}

# 获取所有暴露端口
get_exposed_ports() {
    docker ps --format '{{.Ports}}' | grep -oE '[0-9]+->' | grep -oE '[0-9]+' | sort -u
}

# 对指定端口执行屏蔽/放行操作
apply_port_action() {
    local action="$1"
    local port="$2"
    local cidrs=( $(get_docker_cidrs) )
    local hosts=( $(get_host_ips) )

    for net in "${cidrs[@]}" "${hosts[@]}"; do
        if [[ "$action" == "屏蔽" ]]; then
            if ! iptables -C DOCKER-USER -p tcp --dport "$port" ! -s "$net" -j DROP 2>/dev/null; then
                echo "屏蔽端口 $port 排除 $net"
                iptables -I DOCKER-USER -p tcp --dport "$port" ! -s "$net" -j DROP
            fi
        else
            if iptables -C DOCKER-USER -p tcp --dport "$port" ! -s "$net" -j DROP 2>/dev/null; then
                echo "放行端口 $port 排除 $net"
                iptables -D DOCKER-USER -p tcp --dport "$port" ! -s "$net" -j DROP
            fi
        fi
    done
}

# 批量处理所有暴露端口
manage_all_ports() {
    local action="$1"
    local ports=$(get_exposed_ports)
    if [[ -z "$ports" ]]; then
        $SETCOLOR_WARNING
        echo "未发现对外暴露的端口。"
        $SETCOLOR_NORMAL
        return
    fi
    for port in $ports; do
        apply_port_action "$action" "$port"
    done
}

# 管理单容器端口
manage_single_container() {
    local name=$(get_containers | fzf)
    if [[ -z "$name" ]]; then
        $SETCOLOR_FAILURE; echo "未选择容器"; $SETCOLOR_NORMAL; return
    fi
    local ports=$(docker port "$name" | awk '{print $3}' | cut -d: -f2)
    if [[ -z "$ports" ]]; then
        $SETCOLOR_FAILURE; echo "未发现容器端口"; $SETCOLOR_NORMAL; return
    fi
    echo "容器 $name 暴露端口: $ports"
    read -p "选择操作（1: 屏蔽, 2: 放行）: " opt
    [[ "$opt" == "1" ]] && act="屏蔽" || act="放行"
    for port in $ports; do apply_port_action "$act" "$port"; done
}

# 指定 IP 管控
manage_ip_access() {
    local name=$(get_containers | fzf)
    [[ -z "$name" ]] && echo "未选择容器" && return
    local ports=$(docker port "$name" | awk '{print $3}' | cut -d: -f2)
    [[ -z "$ports" ]] && echo "未获取到端口" && return
    echo "容器 $name 暴露端口: $ports"

    while true; do
        read -p "请输入目标 IP: " ip
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            echo "输入无效，请输入合法的 IPv4 地址（如 192.168.1.100）"
        fi
    done

    read -p "操作（1: 允许, 2: 禁止）: " mode
    for port in $ports; do
        if [[ "$mode" == "1" ]]; then
            iptables -I DOCKER-USER -p tcp --dport "$port" -s "$ip" -j ACCEPT
            echo "已允许 $ip 访问 $port"
        else
            iptables -I DOCKER-USER -p tcp --dport "$port" -s "$ip" -j DROP
            echo "已禁止 $ip 访问 $port"
        fi
    done
}

# 主菜单
main_menu() {
    check_dependencies
    while true; do
        echo -e "\n*************** 防火墙管理菜单 ***************"
        echo "1. 一键屏蔽所有 Docker 暴露端口"
        echo "2. 一键放行所有 Docker 暴露端口"
        echo "3. 管理单独容器端口屏蔽/放行"
        echo "4. 设置指定 IP 对容器的访问权限"
        echo "5. 退出"
        echo "**********************************************"
        read -p "请输入选项: " ch
        case $ch in
            1) manage_all_ports "屏蔽" ;;
            2) manage_all_ports "放行" ;;
            3) manage_single_container ;;
            4) manage_ip_access ;;
            5) echo "退出"; exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

main_menu

