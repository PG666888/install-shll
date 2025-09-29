#!/bin/bash



#'''''''''''''''''''''
# 31 32 33 34 35
# 红 绿 黄 篮 粉红
#.....................

SETCOLOR_SUCCESS="echo -en \\033[1;32m"
SETCOLOR_FAILURE="echo -en \\033[1;31m"
SETCOLOR_WARNING="echo -en \\033[1;33m"
SETCOLOR_NORMAL="echo -en \\033[0;39m"
UNSET_COLOR='\E[0m'


#定义菜单函数
function menu {
    echo -e "\n"
    echo "******************* Menu *******************"
    echo "请从以下选项中进行选择:"
    echo "1. 启用禁PING"
    echo "2. 关闭禁PING"
    echo "3. 开启某个端口"
    echo "4. 关闭某个端口"
    echo "5. 允许指定IP访问指定端口"
    echo "6. 取消指定IP访问指定端口"
    echo "7. 允许指定IP访问所有端口"
    echo "8. 取消指定IP访问所有端口"
    echo "9. 列出默认区域所有规则设置: --list-all"
    echo "10. 查看默认区域所有规则名单: --list-rich-rules"
    echo "11. exit"
    echo "********************************************"
    echo -e "\n"
}


function firewallReload() {
   ARG=$1
   if [[ ${ARG} -eq 0 ]];then
       $SETCOLOR_SUCCESS "firewall-cmd --reload ===>>>" $UNSET_COLOR
       firewall-cmd --reload
   fi
}


# open and close for ping
function func1() {
    ARG=$1
    echo -e "command: "
    $SETCOLOR_WARNING "firewall-cmd --permanent --${ARG}-rich-rule='rule protocol value=icmp drop' ===>>>" $UNSET_COLOR
    firewall-cmd --permanent --${ARG}-rich-rule='rule protocol value=icmp drop'
    firewallReload $?
}

function func2() {
   ARG=$1
   PORT=${2}
   PROTOCOL=${3:-tcp}
   echo -e "command: "
   $SETCOLOR_WARNING "firewall-cmd --permanent --${ARG}-port=${PORT}/${PROTOCOL}' ===>>>" $UNSET_COLOR
   firewall-cmd --permanent --${ARG}-port=${PORT}/${PROTOCOL}
   firewallReload $?
}

function func3() {
   ARG=$1
   ADDR=$2
   PORT=$3
   PROTOCOL=${4:-tcp}
   echo -e "command: "
   $SETCOLOR_WARNING "firewall-cmd --permanent --${ARG}-rich-rule='rule family=\"ipv4\" source address=\"${ADDR}\" port protocol=\"${PROTOCOL}\" port="${PORT}" accept' ===>>>" $UNSET_COLOR
   firewall-cmd --permanent --${ARG}-rich-rule='rule family="ipv4" source address='''${ADDR}''' port protocol='''${PROTOCOL}''' port='''${PORT}''' accept'
   firewallReload $?
}

function func4() {
   ARG=$1
   ADDR=$2
   echo -e "command: "
   $SETCOLOR_WARNING "firewall-cmd --permanent --${ARG}-rich-rule='rule family=\"ipv4\" source address=\"${ADDR}\" accept' ===>>>" $UNSET_COLOR
   firewall-cmd --permanent --${ARG}-rich-rule='rule family="ipv4" source address='''${ADDR}''' accept'
   firewallReload $?
}

function func5() {
   echo -e "command: "
   $SETCOLOR_WARNING "firewall-cmd --list-all ===>>>\n"$UNSET_COLOR
   firewall-cmd --list-all
   $SETCOLOR_WARNING "<<<==="$UNSET_COLOR
}

function func6() {
   echo -e "command: "
   $SETCOLOR_WARNING "firewall-cmd --list-rich-rules ===>>>\n"$UNSET_COLOR
   firewall-cmd --list-rich-rules
   $SETCOLOR_WARNING "<<<==="$UNSET_COLOR
}

#定义主程序
function main {
    while true
    do
        menu
        read -p "请输入数字选择菜单项：" choice
        case $choice in
            1)
                func1 add
                ;;
            2)
                func1 remove
                ;;
            3)
                read -p "请输入允许的端口:" port
                read -p "请输入协议,默认(tcp):" procotol
                func2 add $port $procotol
                ;;
            4)
                read -p "请输入取消的端口:" port
                read -p "请输入取消的协议,默认(tcp):" procotol
                func2 remove $port $procotol
                ;;
            5)
                read -p "请输入允许的IP:" addr
                read -p "请输入允许的端口:" port
                read -p "请输入允许的协议,默认(tcp):" procotol
                func3 add $addr $port $procotol
                ;;
            6)
                read -p "请输入取消的IP:" addr
                read -p "请输入取消的端口:" port
                read -p "请输入取消的协议,默认(tcp):" procotol
                func3 remove $addr $port $procotol
                ;;
            7)
                read -p "请出入IP地址:" addr
                func4 add $addr
                ;;
            8)
                read -p "请输入IP地址:" addr
                func4 remove $addr
                ;;
            9)
                func5
                ;;
            10)
                func6
                ;;
            11)
                echo "Thank you use ! You are good boy! bye bye!!!"
                exit
                ;;
            *)
                echo "无效的选项，请重新输入。"
                ;;
        esac
    done
}

main
