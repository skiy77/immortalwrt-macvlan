#!/bin/bash

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
    ip addr add ${ip_base}.251/24 dev macvlan-shim
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
    local container_ip="${ip_base}.248"
    
    echo "Updating container network configuration..."
    docker exec immortalwrt ash -c "cat > /etc/config/network << 'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd98:9655:39f9::/48'
config interface 'lan'
	option proto 'static'
	option netmask '255.255.255.0'
	option ipbassign '60'
	option ipaddr '${container_ip}'
	option gateway '${gateway}'
	option dns '${gateway}'
	option device 'eth0'
EOF"

    docker exec immortalwrt /etc/init.d/network restart
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
        
        # 确保macvlan-shim接口存在
        if ! check_shim; then
            # 如果不存在，创建接口
            create_shim "$interface" "$gateway"
        else
            # 如果存在，删除并重建
            ip link del macvlan-shim 2>/dev/null || true
            create_shim "$interface" "$gateway"
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
    
    if check_shim; then
        echo "Macvlan-shim interface exists."
        shim_exists=true
    else
        echo "Macvlan-shim interface not found."
    fi
    
    # 创建缺失的组件
    if ! $network_exists; then
        create_macvlan "$interface" "$subnet" "$gateway"
    fi
    
    if ! $shim_exists; then
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