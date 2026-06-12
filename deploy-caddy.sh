#!/bin/bash

# 遇到错误立即停止执行
set -e

# 生成随机强密码
USERNAME="user_$(shuf -i 1000-9999 -n 1)"
PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
CURR_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

# 安全地获取当前 SSH 端口
CURR_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n 1)
: "${CURR_SSH_PORT:=22}" # 如果没获取到，默认22

# 随机生成新 SSH 端口备用
SSH_PORT=$(shuf -i 2000-20000 -n 1)

echo "=== 1. 系统更新与依赖安装 ==="
apt update -y && apt install -y curl wget gnupg lsb-release sed ufw iptables-persistent debconf-utils

# 配置 iptables 自动保存
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

echo "=== 2. 配置防火墙策略 ==="
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 3211 -j ACCEPT
iptables -A INPUT -p tcp --dport "$CURR_SSH_PORT" -j ACCEPT
netfilter-persistent save

echo "=== 3. 优化系统网络参数 (BBR) ==="
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf

cat >>/etc/sysctl.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 131072 8388608
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p

echo "=== 4. 安装 Docker ==="
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

echo "=== 5. 配置 Caddy 环境 ==="
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

# 修复后的 auto-update.sh
cat >/opt/caddy/auto-update.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE="lostos/caddy-naive"

echo "Checking for budget updates..."
docker pull $IMAGE

RUNNING_IMG=$(docker inspect --format "{{.Image}}" caddy 2>/dev/null || echo "")
LATEST_IMG=$(docker inspect --format "{{.Id}}" $IMAGE 2>/dev/null || echo "")

if [ "$RUNNING_IMG" != "$LATEST_IMG" ] || [ -z "$RUNNING_IMG" ]; then
    echo "Upgrading Caddy container..."
    docker rm -f caddy 2>/dev/null || true
    $SCRIPT_DIR/run.sh
    docker image prune -f
else
    echo "Caddy is up to date."
fi
EOF

cat >/opt/caddy/run.sh <<EOF
#!/bin/bash
docker run -d --name="caddy" \\
    --restart=always \\
    -p 80:80/tcp \\
    -p 443:443/tcp \\
    -p 443:443/udp \\
    -p 3211:3211/udp \\
    -v /opt/caddy/Caddyfile:/app/Caddyfile \\
    -v /var/www/html:/var/www/html \\
    -e UDP_OVER_TCP_PASSWORD=$PASSWORD \\
    lostos/caddy-naive
EOF

chmod +x /opt/caddy/auto-update.sh /opt/caddy/run.sh

# 定时任务
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
            # 先确保新端口在防火墙中放行
            iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
            netfilter-persistent save
            
            # 安全精确地修改 SSH 端口
            if grep -q "^#Port 22" /etc/ssh/sshd_config; then
                sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
            elif grep -q "^Port " /etc/ssh/sshd_config; then
                sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
            else
                echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
            fi
            
            systemctl restart sshd
            echo "[成功] SSH 端口已修改为 $SSH_PORT。请务必开辟新终端测试能否连入，切勿直接关闭当前窗口！"
            ;;
        *)
            echo "已跳过修改 SSH 端口。"
            ;;
    esac
fi
