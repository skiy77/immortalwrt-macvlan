#!/bin/bash

# 配置选项
# 设置为1启用macvlan-shim，设置为0禁用macvlan-shim
MACVLAN_SHIM_ENABLED=0

# rootfs.tar.gz下载地址
ROOTFS_URL="https://downloads.immortalwrt.org/releases/24.10.1/targets/armsr/armv8/immortalwrt-24.10.1-armsr-armv8-rootfs.tar.gz"

# IP地址配置
CONTAINER_IP_LAST_OCTET=248  # 容器IP地址最后一位
SHIM_IP_LAST_OCTET=251      # macvlan-shim接口IP地址最后一位

# 检查Docker是否安装
check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        echo "错误: Docker未安装，无法运行此脚本。"
        echo "请先安装Docker后再运行。"
        exit 1
    fi
}

# 检查immortalwrt-image镜像是否存在
check_image_exists() {
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^immortalwrt-image:latest$"; then
        echo "镜像 'immortalwrt-image' 不存在，将创建镜像..."
        create_image
    else
        echo "镜像 'immortalwrt-image' 已存在，继续运行..."
    fi
}

# 创建immortalwrt-image镜像
create_image() {
    echo "开始创建immortalwrt-image镜像..."
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    echo "下载并解压rootfs.tar.gz..."
    echo "使用下载地址: $ROOTFS_URL"
    wget -O rootfs.tar.gz "$ROOTFS_URL"
    if [ $? -ne 0 ]; then
        echo "下载rootfs.tar.gz失败，请检查网络连接或URL是否有效。"
        echo "当前URL: $ROOTFS_URL"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    gzip -d rootfs.tar.gz
    if [ $? -ne 0 ]; then
        echo "解压rootfs.tar.gz失败。"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    echo "创建Dockerfile..."
    cat <<EOF >"Dockerfile"
FROM scratch
ADD rootfs.tar /
EOF
    
    echo "构建Docker镜像..."
    docker build -t immortalwrt-image .
    if [ $? -ne 0 ]; then
        echo "构建Docker镜像失败。"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    echo "清理临时文件..."
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    echo "镜像创建成功！"
}

# 获取当前网络配置
get_current_network() {
    local interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    local gateway=$(ip route | grep default | awk '{print $3}' | head -n 1)
    local ip_base=$(echo "$gateway" | cut -d. -f1-3)
    local subnet="${ip_base}.0/24"
    echo "${interface}|${gateway}|${subnet}"
}

# 检查容器是否存在
check_container() {
    docker ps -a --format '{{.Names}}' | grep -q "^immortalwrt$"
}

# 检查网络是否存在
check_network() {
    docker network ls --format '{{.Name}}' | grep -q "^macnet$"
}

# 检查macvlan-shim接口是否存在
check_shim() {
    ip link show macvlan-shim >/dev/null 2>&1
}

# 创建macvlan网络
create_macvlan() {
    local interface=$1
    local subnet=$2
    local gateway=$3
    
    echo "Creating macvlan network..."
    docker network create -d macvlan \
        --subnet=$subnet \
        --gateway=$gateway \
        -o parent=$interface \
        macnet
}

# 创建macvlan-shim接口
create_shim() {
    local interface=$1
    local gateway=$2
    local ip_base=$(echo $gateway | cut -d. -f1-3)
    
    echo "Creating macvlan-shim interface..."
    ip link add macvlan-shim link $interface type macvlan mode bridge
    ip addr add ${ip_base}.${SHIM_IP_LAST_OCTET}/24 dev macvlan-shim
    ip link set macvlan-shim up
}

# 创建容器
create_container() {
    echo "Creating immortalwrt container..."
    docker run --name immortalwrt -d \
        --network macnet \
        --privileged \
        --restart=always \
        immortalwrt-image:latest \
        /sbin/init
}

# 更新网络配置
update_network_config() {
    local gateway=$1
    local ip_base=$(echo $gateway | cut -d. -f1-3)
    local container_ip="${ip_base}.${CONTAINER_IP_LAST_OCTET}"
    
    echo "Updating container network configuration..."
    
    # 检查容器内是否已存在网络配置
    local config_exists=$(docker exec immortalwrt ash -c "[ -f /etc/config/network ] && echo 'yes' || echo 'no'")
    
    # 检查lan接口是否存在，以及网关和DNS是否已配置
    if [ "$config_exists" = "no" ] || \
       [ "$(docker exec immortalwrt ash -c "uci show network.lan 2>/dev/null || echo 'missing'")" = "missing" ] || \
       [ "$(docker exec immortalwrt ash -c "uci -q get network.lan.gateway || echo 'missing'")" = "missing" ] || \
       [ "$(docker exec immortalwrt ash -c "uci -q get network.lan.dns || echo 'missing'")" = "missing" ]; then
        # 如果配置不存在或lan接口未配置，创建完整配置
        echo "Creating new network configuration..."
        docker exec immortalwrt ash -c "cat > /etc/config/network << 'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd98:9655:39f9::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option proto 'static'
	option netmask '255.255.255.0'
	option ipbassign '60'
	option ipaddr '${container_ip}'
	option gateway '${gateway}'
	option dns '${gateway}'
	option device 'br-lan'

config device
    option name 'eth0'
    option macaddr '8E:DB:A9:15:BA:83'

EOF"
    else
        # 如果配置已存在，只更新必要的参数
        echo "Updating existing network configuration..."
        docker exec immortalwrt ash -c "
            # 更新IP地址
            uci set network.lan.ipaddr='${container_ip}'
            # 更新网关
            uci set network.lan.gateway='${gateway}'
            # 更新DNS
            uci set network.lan.dns='${gateway}'
            # 保存更改
            uci commit network
        "
    fi

    # 重启网络服务以应用更改
    docker exec immortalwrt /etc/init.d/network restart
    
    echo "Network configuration in container updated."
}

# 更新网络配置
update_network_configuration() {
    local interface=$1
    local gateway=$2
    local subnet=$3
    
    # 检查容器是否在运行
    local container_running=$(docker inspect -f '{{.State.Running}}' immortalwrt 2>/dev/null || echo "false")
    
    # 如果容器未运行，先启动它
    if [ "$container_running" != "true" ]; then
        echo "Container is not running. Starting it first..."
        docker start immortalwrt
        
        # 等待容器启动，最多等待30秒
        local max_wait=30
        local wait_time=0
        while [ "$wait_time" -lt "$max_wait" ]; do
            sleep 1
            wait_time=$((wait_time + 1))
            container_running=$(docker inspect -f '{{.State.Running}}' immortalwrt 2>/dev/null || echo "false")
            if [ "$container_running" = "true" ]; then
                echo "Container started successfully after $wait_time seconds."
                sleep 5  # 额外等待5秒确保服务启动
                break
            fi
        done
        
        if [ "$container_running" != "true" ]; then
            echo "Container failed to start within $max_wait seconds. Will force network update."
            # 强制更新网络配置
            container_gateway="force_update"
        fi
    fi
    
    # 获取容器当前网关
    if [ "$container_running" = "true" ]; then
        # 尝试获取网关，最多尝试3次
        local retry=0
        local max_retry=3
        container_gateway="unknown"
        
        while [ "$retry" -lt "$max_retry" ] && [ "$container_gateway" = "unknown" ]; do
            container_gateway=$(docker exec immortalwrt ash -c "uci get network.lan.gateway" 2>/dev/null || echo "unknown")
            if [ "$container_gateway" = "unknown" ]; then
                retry=$((retry + 1))
                echo "Failed to get gateway, retrying ($retry/$max_retry)..."
                sleep 2
            fi
        done
    else
        container_gateway="force_update"
    fi
    
    # 如果网关不同或强制更新，需要更新配置
    if [ "$container_gateway" = "unknown" ] || [ "$container_gateway" = "force_update" ] || [ "$container_gateway" != "$gateway" ]; then
        echo "Container network configuration mismatch or needs update. Updating..."
        
        # 停止容器（但不删除）
        docker stop immortalwrt
        
        # 断开容器与旧网络的连接
        docker network disconnect macnet immortalwrt 2>/dev/null || true
        
        # 确保macnet网络存在
        if ! check_network; then
            # 如果不存在，创建网络
            create_macvlan "$interface" "$subnet" "$gateway"
        else
            # 如果存在，删除并重建
            docker network rm macnet
            create_macvlan "$interface" "$subnet" "$gateway"
        fi
        
        # 只有在启用macvlan-shim时才处理shim接口
        if [ "$MACVLAN_SHIM_ENABLED" -eq 1 ]; then
            # 确保macvlan-shim接口存在
            if ! check_shim; then
                # 如果不存在，创建接口
                create_shim "$interface" "$gateway"
            else
                # 如果存在，删除并重建
                ip link del macvlan-shim 2>/dev/null || true
                create_shim "$interface" "$gateway"
            fi
        else
            echo "Macvlan-shim is disabled in configuration. Skipping shim interface setup."
        fi
        
        # 连接容器到新网络
        docker network connect macnet immortalwrt
        
        # 启动容器
        docker start immortalwrt
        sleep 5
        
        # 更新容器网络配置
        update_network_config "$gateway"
        
        echo "Network configuration updated successfully."
    else
        echo "Container network configuration is correct. No changes needed."
    fi
}

# 主函数
main() {
    # 检查Docker是否安装
    check_docker_installed
    
    # 检查镜像是否存在
    check_image_exists
    
    # 获取当前网络信息
    IFS='|' read -r interface gateway subnet <<< "$(get_current_network)"
    
    echo "Current network configuration:"
    echo "Interface: $interface"
    echo "Gateway: $gateway"
    echo "Subnet: $subnet"
    
    # 分别检查各组件是否存在
    local container_exists=false
    local network_exists=false
    local shim_exists=false
    
    if check_container; then
        echo "Container 'immortalwrt' exists."
        container_exists=true
    else
        echo "Container 'immortalwrt' not found."
    fi
    
    if check_network; then
        echo "Macvlan network 'macnet' exists."
        network_exists=true
    else
        echo "Macvlan network 'macnet' not found."
    fi
    
    # 只有在启用macvlan-shim时才检查和创建
    if [ "$MACVLAN_SHIM_ENABLED" -eq 1 ]; then
        if check_shim; then
            echo "Macvlan-shim interface exists."
            shim_exists=true
        else
            echo "Macvlan-shim interface not found."
        fi
    else
        echo "Macvlan-shim is disabled in configuration."
        shim_exists=true  # 设为true以跳过创建
    fi
    
    # 创建缺失的组件
    if ! $network_exists; then
        create_macvlan "$interface" "$subnet" "$gateway"
    fi
    
    # 只有在启用macvlan-shim时才创建
    if [ "$MACVLAN_SHIM_ENABLED" -eq 1 ] && ! $shim_exists; then
        create_shim "$interface" "$gateway"
    fi
    
    if ! $container_exists; then
        create_container
        sleep 5
        update_network_config "$gateway"
    else
        # 容器存在，检查并更新网络配置
        update_network_configuration "$interface" "$gateway" "$subnet"
    fi
    
    echo "Setup completed."
}

main