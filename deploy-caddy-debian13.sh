#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-caddy-debian13.sh) 

# 遇到错误立即停止执行
set -e

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本！"
    exit 1
fi

# 生成随机强密码
USERNAME="user_$(shuf -i 1000-9999 -n 1)"
PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
CURR_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

# 安全地获取当前 SSH 端口（兼容 Debian 13 新版 ss 工具）
CURR_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n 1)
: "${CURR_SSH_PORT:=22}"

# 随机生成新 SSH 端口备用
SSH_PORT=$(shuf -i 2000-20000 -n 1)

echo "=== 1. 系统更新与基础依赖安装 ==="
apt update -y && apt install -y curl wget gnupg sed ufw

echo "=== 2. 配置防火墙策略 (使用 UFW 兼容 Debian 13) ==="
# 默认允许所有流出，拒绝所有流入
ufw default deny incoming
ufw default allow outgoing

# 放行必要端口
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 3211/udp
ufw allow "$CURR_SSH_PORT"/tcp

# 激活防火墙（--force 避免交互提示）
ufw --force enable

echo "=== 3. 优化系统网络参数 (BBR & Debian 13 高性能 UDP 优化) ==="

# 定义一个独立的配置文件，专门存放自定义网络优化参数
SYSCTL_CONF="/etc/sysctl.d/99-network-optimize.conf"

# 直接清空或创建该文件，避免用 sed 去修改旧文件报错
rm -f "$SYSCTL_CONF"

cat > "$SYSCTL_CONF" <<EOF
# TCP BBR 优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 131072 8388608
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3

# QUIC / UDP 缓冲区优化 (Debian 13 内核必备)
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
EOF

# 应用所有 sysctl 配置（包括 sysctl.d 目录下的新文件）
sysctl --system

echo "=== 4. 安装 Docker (兼容 Debian 13 trixie) ==="
if ! command -v docker &> /dev/null; then
    # 使用官方一键脚本，能够自动识别 trixie 源，若无匹配则会自动安全降级到 bookworm 源
    curl -fsSL https://get.docker.com | sh
fi

echo "=== 5. 配置 Caddy 运行环境 ==="
mkdir -p /opt/caddy /var/www/html

cat >/opt/caddy/Caddyfile <<EOF
{
    order forward_proxy before file_server
    acme_ca https://acme.zerossl.com/v2/DV90
}
:443, yourdomain.com {
    tls mail@yourdomain.com
    forward_proxy {
        basic_auth $USERNAME $PASSWORD
        hide_ip
        hide_via
        probe_resistance
    }
    file_server {
        root /var/www/html
    }
}
EOF

# 自动更新脚本
cat >/opt/caddy/auto-update.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="lostos/caddy-naive"

echo "正在检查镜像更新..."
docker pull $IMAGE

RUNNING_IMG=$(docker inspect --format "{{.Image}}" caddy 2>/dev/null || echo "")
LATEST_IMG=$(docker inspect --format "{{.Id}}" $IMAGE 2>/dev/null || echo "")

if [ "$RUNNING_IMG" != "$LATEST_IMG" ] || [ -z "$RUNNING_IMG" ]; then
    echo "发现更新，正在重启 Caddy 容器..."
    docker rm -f caddy 2>/dev/null || true
    $SCRIPT_DIR/run.sh
    docker image prune -f
else
    echo "Caddy 已经是最新版本。"
fi
EOF

cat >/opt/caddy/run.sh <<EOF
#!/bin/bash
docker run -d --name="caddy" \\
    --restart=always \\
    -p 80:80/tcp \\
    -p 443:443/tcp \\
    -p 443:443/udp \\
    -p 3211:3211/tcp \\
    -p 3211:3211/udp \\
    -v /opt/caddy/Caddyfile:/app/Caddyfile \\
    -v /var/www/html:/var/www/html \\
    -e UDP_OVER_TCP_PASSWORD=$PASSWORD \\
    lostos/caddy-naive
EOF

chmod +x /opt/caddy/auto-update.sh /opt/caddy/run.sh

# 定时任务 (兼容旧版及新版 cron 行为)
crontab -l 2>/dev/null | grep -v "/opt/caddy/auto-update.sh" > mycron || true
echo "0 3 * * * /opt/caddy/auto-update.sh" >> mycron
crontab mycron && rm mycron

# 启动服务
docker rm -f "caddy" 2>/dev/null || true
/opt/caddy/run.sh

echo "--------------------------------------------------"
echo "安装完成！"
echo "1. 请移步 /opt/caddy/Caddyfile 修改 yourdomain.com 和 邮箱。"
echo "2. 请在 /var/www/html 放入你的伪装网站静态页面。"
echo "3. 自动生成的代理凭证如下（已写入配置）："
echo "   Username: $USERNAME"
echo "   Password: $PASSWORD"
echo "--------------------------------------------------"

# 安全修改 SSH 端口逻辑
if [ "$CURR_SSH_PORT" = "22" ]; then
    echo "检测到当前 SSH 端口为默认的 22。"
    read -p "是否想将 SSH 端口修改为 $SSH_PORT ？[y/N] " yn
    case $yn in
        [Yy])
            # 先确保新端口在 UFW 防火墙中放行
            ufw allow "$SSH_PORT"/tcp
            
            # 安全精确地修改 SSH 配置文件
            if grep -q "^#Port 22" /etc/ssh/sshd_config; then
                sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
            elif grep -q "^Port " /etc/ssh/sshd_config; then
                sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
            else
                echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
            fi
            
            # 重启服务
            systemctl restart sshd
            echo "[成功] SSH 端口已修改为 $SSH_PORT。请务必新开一个终端窗口测试连接，切勿直接关闭当前窗口！"
            ;;
        *)
            echo "已跳过修改 SSH 端口。"
            ;;
    esac
fi
