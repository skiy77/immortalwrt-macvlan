#!/bin/bash

# 检查是否以root权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要root权限运行" 1>&2
   exit 1
fi

# 复制监控脚本到系统目录
echo "安装监控脚本..."
cp docker-network-monitor.sh /usr/local/bin/
chmod +x /usr/local/bin/docker-network-monitor.sh

# 复制服务文件到systemd目录
echo "安装systemd服务..."
cp docker-network-monitor.service /etc/systemd/system/

# 首次运行脚本
echo "执行首次运行配置..."
echo "这将创建必要的网络配置和容器..."
/usr/local/bin/docker-network-monitor.sh
echo "首次运行配置完成"
echo ""

# 重新加载systemd配置
echo "重新加载systemd配置..."
systemctl daemon-reload

# 启用并启动服务
echo "启用并启动服务..."
systemctl enable docker-network-monitor.service
systemctl start docker-network-monitor.service

echo "安装完成！服务已启动并设置为开机自启动。"
echo "可以通过以下命令查看服务状态："
echo "systemctl status docker-network-monitor.service"
echo ""
echo "可以通过以下命令查看服务日志："
echo "journalctl -u docker-network-monitor.service -n 50"