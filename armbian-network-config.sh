#!/bin/bash

# 配置选项
# 设置为1关闭IPv6，设置为0保持IPv6开启
DISABLE_IPV6=1

# 获取当前活动的网络接口
get_network_interface() {
    # 获取默认路由对应的接口
    local iface=$(ip route | awk '/default/ {print $5}' | head -n1)
    if [ -z "$iface" ]; then
        echo "错误：无法确定网络接口"
        exit 1
    fi
    echo "$iface"
}

# 获取指定接口的IP地址
get_source_ip() {
    local iface=$1
    local ip=$(ip addr show $iface | grep -w inet | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$ip" ]; then
        echo "错误：无法获取接口 $iface 的IP地址"
        exit 1
    fi
    echo "$ip"
}

# 自动获取网络配置
NETWORK_INTERFACE=$(get_network_interface)
SOURCE_IP=$(get_source_ip $NETWORK_INTERFACE)

# 显示使用说明
show_usage() {
    echo "使用说明："
    echo "  $0 [g=网关IP] [n=DNS服务器IP]"
    echo ""
    echo "参数："
    echo "  g=网关IP     设置新的默认网关"
    echo "  n=DNS服务器IP 设置新的DNS服务器"
    echo ""
    echo "示例："
    echo "  $0 g=192.168.1.1          # 仅修改默认网关"
    echo "  $0 n=192.168.1.1          # 仅修改DNS服务器"
    echo "  $0 g=192.168.1.1 n=192.168.1.1  # 同时修改网关和DNS"
    echo ""
    echo "注意："
    echo "  - 网关和DNS的修改为临时修改，系统重启后将恢复默认设置"
    echo "  - 必须使用root权限运行此脚本"
}

# 检查IP地址格式是否有效
is_valid_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        for i in {1..4}; do
            if [ $(echo "$ip" | cut -d. -f$i) -gt 255 ]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 解析命令行参数
parse_args() {
    local gateway=""
    local dns=""
    
    # 遍历所有参数
    for arg in "$@"; do
        # 检查网关参数
        if [[ $arg =~ ^g=([0-9.]+)$ ]]; then
            gateway="${BASH_REMATCH[1]}"
            if ! is_valid_ip "$gateway"; then
                echo "错误：无效的网关IP地址格式"
                show_usage
                exit 1
            fi
        # 检查DNS参数
        elif [[ $arg =~ ^n=([0-9.]+)$ ]]; then
            dns="${BASH_REMATCH[1]}"
            if ! is_valid_ip "$dns"; then
                echo "错误：无效的DNS服务器IP地址格式"
                show_usage
                exit 1
            fi
        else
            echo "错误：无效的参数 '$arg'"
            show_usage
            exit 1
        fi
    done
    
    # 如果没有提供任何参数，显示使用说明
    if [ -z "$gateway" ] && [ -z "$dns" ]; then
        show_usage
        exit 0
    fi
    
    # 设置全局变量
    NEW_GATEWAY="$gateway"
    NEW_DNS="$dns"
}

# 检查是否以root权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要root权限运行" 1>&2
   exit 1
fi

# 函数：关闭IPv6
disable_ipv6() {
    echo "正在配置IPv6设置..."
    
    # 检查/etc/sysctl.conf文件是否存在
    if [ ! -f /etc/sysctl.conf ]; then
        echo "错误: /etc/sysctl.conf文件不存在"
        return 1
    fi
    
    # 备份原始文件
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    echo "已备份原始配置文件到 /etc/sysctl.conf.bak"
    
    # 修改配置文件
    # 1. 禁用IPv6
    if grep -q "^#\?net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
        # 如果行存在（可能被注释），取消注释并设置为1
        sed -i 's/^#\?net.ipv6.conf.all.disable_ipv6.*/net.ipv6.conf.all.disable_ipv6 = 1/' /etc/sysctl.conf
    else
        # 如果行不存在，添加它
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    
    if grep -q "^#\?net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf; then
        # 如果行存在（可能被注释），取消注释并设置为1
        sed -i 's/^#\?net.ipv6.conf.default.disable_ipv6.*/net.ipv6.conf.default.disable_ipv6 = 1/' /etc/sysctl.conf
    else
        # 如果行不存在，添加它
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    
    # 2. 禁用IPv6转发
    if grep -q "^#\?net.ipv6.conf.default.forwarding" /etc/sysctl.conf; then
        # 如果行存在（可能被注释），取消注释并设置为0
        sed -i 's/^#\?net.ipv6.conf.default.forwarding.*/net.ipv6.conf.default.forwarding = 0/' /etc/sysctl.conf
    else
        # 如果行不存在，添加它
        echo "net.ipv6.conf.default.forwarding = 0" >> /etc/sysctl.conf
    fi
    
    if grep -q "^#\?net.ipv6.conf.all.forwarding" /etc/sysctl.conf; then
        # 如果行存在（可能被注释），取消注释并设置为0
        sed -i 's/^#\?net.ipv6.conf.all.forwarding.*/net.ipv6.conf.all.forwarding = 0/' /etc/sysctl.conf
    else
        # 如果行不存在，添加它
        echo "net.ipv6.conf.all.forwarding = 0" >> /etc/sysctl.conf
    fi
    
    # 应用修改
    echo "应用sysctl配置..."
    sysctl -p
    
    # 检查IPv6状态
    echo "检查IPv6状态..."
    ipv6_status=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    if [ "$ipv6_status" == "1" ]; then
        echo "IPv6已成功禁用"
    else
        echo "警告: IPv6可能未完全禁用，请检查系统配置"
    fi
    
    echo "IPv6地址检查:"
    ip a | grep inet6 || echo "未发现IPv6地址，配置成功"
}

# 函数：修改默认网关
change_gateway() {
    if [ -z "$NEW_GATEWAY" ]; then
        return 0
    fi
    
    echo "正在修改默认网关..."
    
    # 删除当前默认网关
    echo "删除当前默认网关..."
    ip route del default
    
    # 添加新的默认网关
    echo "添加新的默认网关: $NEW_GATEWAY"
    ip route add default via $NEW_GATEWAY dev $NETWORK_INTERFACE proto dhcp src $SOURCE_IP metric 100
    
    # 检查网关配置
    echo "检查网关配置:"
    ip route | grep default
    
    echo "注意: 此修改为临时修改，系统重启后将恢复默认设置"
}

# 函数：修改DNS
change_dns() {
    if [ -z "$NEW_DNS" ]; then
        return 0
    fi
    
    echo "正在修改DNS服务器..."
    
    # 备份原始resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo "已备份原始DNS配置到 /etc/resolv.conf.bak"
    
    # 修改resolv.conf
    echo "nameserver $NEW_DNS" > /etc/resolv.conf
    
    # 检查DNS配置
    echo "检查DNS配置:"
    cat /etc/resolv.conf | grep nameserver
    
    echo "注意: 此修改为临时修改，系统重启后将恢复默认设置"
}

# 主函数
main() {
    echo "===== Armbian网络配置工具 ====="
    
    # 解析命令行参数
    parse_args "$@"
    
    # 根据配置执行相应操作
    if [ "$DISABLE_IPV6" -eq 1 ]; then
        disable_ipv6
        echo ""
    fi
    
    if [ -n "$NEW_GATEWAY" ]; then
        change_gateway
        echo ""
    fi
    
    if [ -n "$NEW_DNS" ]; then
        change_dns
        echo ""
    fi
    
    echo "配置完成!"
}

# 执行主函数，传入所有命令行参数
main "$@"