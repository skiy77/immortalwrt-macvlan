# Docker网络监控服务

此服务用于自动检测宿主网段变化（DHCP），并相应地更新Docker macvlan网络和容器网络配置。

## 功能

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

## 文件说明

- `docker-network-monitor.sh`: 主监控脚本
- `docker-network-monitor.service`: systemd服务文件
- `install.sh`: 安装脚本

## 安装步骤

### Linux系统

1. 确保已安装Docker并且immortalwrt容器已经创建
2. 将所有文件下载到同一目录
3. 运行安装脚本（需要root权限）:

```bash
sudo bash install.sh
```

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

如需修改这些配置，请编辑`docker-network-monitor.sh`文件中的相应变量。

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

1. Docker服务是否正在运行
2. immortalwrt容器是否存在
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