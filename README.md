# Docker网络监控服务

此服务用于自动检测宿主网段变化（DHCP），并相应地更新Docker macvlan网络和容器网络配置。

## 功能

- 在脚本运行前检查必要的环境：
  * Docker是否已安装（未安装时会提示并退出）
  * immortalwrt-image镜像是否存在（不存在时会自动创建-适合SOC为armsr/armv8）

- 在系统启动时分别检查以下组件是否存在：
  * immortalwrt容器
  * macnet网络
  * macvlan-shim接口

- 针对不存在的组件单独创建：
  * 如果macnet网络不存在，创建网络
  * 如果macvlan-shim接口不存在，创建接口
  * 如果immortalwrt容器不存在，创建容器

- 如果容器已存在：
  * 绝不删除现有容器，保留所有容器数据
  * 如果容器未运行，先尝试启动容器
  * 检查容器内网段与宿主机网段是否一致
  * 在以下情况下更新网络配置：
    - 网段不一致
    - 容器无法启动
    - 无法获取容器网络配置
  * 更新流程：
    - 停止容器（但不删除）
    - 断开容器与旧网络的连接
    - 更新macnet网络和macvlan-shim接口
    - 重新连接容器到更新后的网络
    - 更新容器内网络配置
    - 重启容器网络服务
  * 如果一致且容器正常运行，保持现有配置不变

## 自动镜像创建

如果系统中不存在 immortalwrt-image 镜像，脚本会自动执行以下步骤来创建：

1. 下载 ImmortalWrt rootfs
   - 自动下载 rootfs.tar.gz 文件
   - 下载地址可通过脚本开头的 ROOTFS_URL 变量配置
   - 默认下载 immortalwrt-24.10.1-armsr-armv8-rootfs.tar.gz
   - 如需使用其他版本或架构，请修改 ROOTFS_URL 变量
   - 解压下载的文件

2. 创建 Docker 镜像
   - 自动创建必要的 Dockerfile
   - 构建 immortalwrt-image 镜像
   - 清理临时文件

注意：镜像创建过程需要网络连接，请确保您的系统能够访问互联网。整个过程是自动的，无需手动干预。

## 文件说明

- `docker-network-monitor.sh`: 主监控脚本
- `docker-network-monitor.service`: systemd服务文件
- `install.sh`: 安装脚本

## 安装步骤

### Linux系统

1. 确保已安装Docker（脚本会自动检测，未安装时会提示）
2. 将所有文件下载到同一目录
3. 运行安装脚本（需要root权限）:

```bash
sudo bash install.sh
```

安装过程中会自动执行首次运行配置，您将看到：
- Docker安装检查
- 镜像存在性检查（如果不存在会自动创建）
- 网络配置创建
- 容器创建和配置

### Windows系统

对于Windows系统，需要手动执行以下步骤：

1. 将`docker-network-monitor.sh`脚本复制到WSL或Docker容器内的适当位置
2. 根据Windows环境修改脚本中的网络接口检测逻辑
3. 设置定时任务或使用Windows服务来运行脚本

## 配置说明

### 网络配置模板

1. **Macvlan网络 (macnet)**
```bash
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth0 \
  macnet
```

2. **Macvlan-shim接口**
```bash
ip link add macvlan-shim link eth0 type macvlan mode bridge
ip addr add 192.168.1.251/24 dev macvlan-shim
ip link set macvlan-shim up
```

3. **Docker容器**
```bash
docker run --name immortalwrt -d \
  --network macnet \
  --privileged \
  --restart=always \
  immortalwrt-image:latest \
  /sbin/init
```

### 默认配置
- 容器名称: `immortalwrt`
- 容器镜像: `immortalwrt-image:latest`
- macvlan网络名称: `macnet`
- shim接口名称: `macvlan-shim`
- shim接口IP: 宿主机网段.251（例如：192.168.1.251/24）
- 容器IP: 宿主机网段.248（例如：192.168.1.248）
- 子网配置: 自动从网关IP推导（例如：网关为192.168.1.1时，子网为192.168.1.0/24）
- macvlan-shim开关: 默认启用 (MACVLAN_SHIM_ENABLED=1)
- rootfs下载地址: 默认为ImmortalWrt 24.10.1 armsr/armv8版本 (可通过ROOTFS_URL变量配置)
- 容器IP最后一位: 默认248 (可通过CONTAINER_IP_LAST_OCTET变量配置)
- macvlan-shim IP最后一位: 默认251 (可通过SHIM_IP_LAST_OCTET变量配置)

如需修改这些配置，请编辑`docker-network-monitor.sh`文件中的相应变量。

### Macvlan-Shim配置
脚本现在支持通过配置选项控制是否启用macvlan-shim功能：

- `MACVLAN_SHIM_ENABLED=1`: 启用macvlan-shim（默认值）
  * 创建macvlan-shim接口，允许宿主机与容器网络通信
  * 保持完整的网络功能，包括宿主机与容器的双向通信

- `MACVLAN_SHIM_ENABLED=0`: 禁用macvlan-shim
  * 不创建macvlan-shim接口
  * 适用于遇到macvlan-shim相关问题的情况
  * 注意：禁用后宿主机将无法直接与容器通信

要修改此设置，请编辑`docker-network-monitor.sh`文件开头的`MACVLAN_SHIM_ENABLED`变量。

### Rootfs下载配置
脚本支持自定义rootfs.tar.gz的下载地址，方便使用不同版本或架构的ImmortalWrt：

- 默认值：`https://downloads.immortalwrt.org/releases/24.10.1/targets/armsr/armv8/immortalwrt-24.10.1-armsr-armv8-rootfs.tar.gz`
- 配置方法：编辑`docker-network-monitor.sh`文件开头的`ROOTFS_URL`变量

自定义下载地址的常见用途：
- 使用不同版本的ImmortalWrt（如21.02、22.03等）
- 使用不同架构的ImmortalWrt（如x86_64、mipsel等）
- 使用本地镜像或更快的下载源
- 使用自定义构建的rootfs

注意：确保提供的URL指向有效的ImmortalWrt rootfs.tar.gz文件，否则镜像创建将失败。

### IP地址配置
脚本支持自定义容器和macvlan-shim接口的IP地址最后一位：

1. 容器IP配置 (CONTAINER_IP_LAST_OCTET)
   - 默认值：248
   - 示例：如果网关是192.168.1.1，容器IP将是192.168.1.248
   - 配置方法：编辑脚本开头的CONTAINER_IP_LAST_OCTET变量

2. Macvlan-shim接口IP配置 (SHIM_IP_LAST_OCTET)
   - 默认值：251
   - 示例：如果网关是192.168.1.1，shim接口IP将是192.168.1.251
   - 配置方法：编辑脚本开头的SHIM_IP_LAST_OCTET变量

注意事项：
- 确保选择的IP地址未被网络中其他设备使用
- 建议使用较高的数字（如200以上）以避免与DHCP分配的IP冲突
- 容器IP和shim接口IP不能相同
- 如果更改了IP配置，需要重新运行脚本以应用新的配置

### 网络配置说明
- 脚本会自动从网关地址推导子网配置
- 例如：如果网关是192.168.1.1，则：
  * 子网会被设置为192.168.1.0/24
  * shim接口IP为192.168.1.251
  * 容器IP为192.168.1.248
- 所有IP地址都使用/24子网掩码（255.255.255.0）

## 运行方式

服务将在系统启动时运行一次，检查并配置网络。它不会持续监控网络变化，而是：
- 在系统启动时执行一次检查
- 如果检测到网络配置变化，会自动更新相关配置
- 完成配置后服务将保持退出状态，直到下次系统启动

## 日志查看

可以通过以下命令查看服务状态和日志：

```bash
# 查看服务状态
systemctl status docker-network-monitor.service

# 查看上次运行的日志
journalctl -u docker-network-monitor.service -n 50
```

## 手动运行

如果需要在系统运行期间手动更新网络配置，可以执行：

```bash
systemctl restart docker-network-monitor.service
```

## 故障排除

如果服务无法正常工作，请检查：

1. Docker是否已正确安装
   - 运行 `docker --version` 验证Docker安装
   - 如果未安装，请先安装Docker
2. immortalwrt-image镜像是否存在
   - 运行 `docker images | grep immortalwrt-image` 检查
   - 如果自动创建失败，检查网络连接和下载URL是否有效
3. Docker服务是否正在运行
4. immortalwrt容器是否存在
3. 网络接口是否正确识别
4. 日志中是否有错误信息
5. 系统启动顺序是否正确（确保网络和Docker服务已经完全启动）
6. 容器是否能正常启动（可以手动尝试 `docker start immortalwrt`）
7. 容器内网络配置是否正确（可以通过 `docker exec immortalwrt ash -c "cat /etc/config/network"` 查看）

### 常见问题

1. **容器无法启动**：
   - 检查容器日志：`docker logs immortalwrt`
   - 可能是由于网络配置错误导致，脚本会尝试修复这种情况

2. **网络配置不正确**：
   - 如果脚本无法自动修复，可以手动重置网络：
     ```bash
     docker stop immortalwrt
     docker network disconnect macnet immortalwrt
     docker network rm macnet
     ip link del macvlan-shim
     systemctl restart docker-network-monitor.service
     ```

## 卸载

如需卸载服务，请运行：

```bash
sudo systemctl stop docker-network-monitor.service
sudo systemctl disable docker-network-monitor.service
sudo rm /etc/systemd/system/docker-network-monitor.service
sudo rm /usr/local/bin/docker-network-monitor.sh
sudo rm -rf /var/lib/docker-network-monitor
```