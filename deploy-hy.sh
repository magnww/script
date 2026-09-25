#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-hy.sh)

# 遇到错误立即停止执行
set -e

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本！"
    exit 1
fi

CURR_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")

# 安全地获取当前 SSH 端口（兼容 Debian 13 新版 ss 工具）
CURR_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n 1)
: "${CURR_SSH_PORT:=22}"

# 随机生成新 SSH 端口备用
SSH_PORT=$(shuf -i 2000-20000 -n 1)

# ACME 签发依赖域名，无法自动推导，必须由使用者提供
while [ -z "$HY_DOMAIN" ]; do
    read -p "请输入域名（需已将 A 记录解析到本机 IP ${CURR_IP}）: " HY_DOMAIN
done

read -p "请输入 ACME 证书通知邮箱: " HY_EMAIL
while [ -z "$HY_EMAIL" ]; do
    read -p "邮箱不能为空，请重新输入: " HY_EMAIL
done

# masquerade 伪装站点，回车采用默认值
read -p "请输入伪装目标站点 URL [https://zozo.jp/]: " HY_MASQ
: "${HY_MASQ:=https://zozo.jp/}"

# 域名解析与公网 IP 不一致时 ACME 必然失败，提前警告而非事后排查
if [ "$CURR_IP" != "YOUR_SERVER_IP" ] && command -v getent >/dev/null 2>&1; then
    RESOLVED_IP=$(getent hosts "$HY_DOMAIN" | awk '{print $1; exit}')
    if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "$CURR_IP" ]; then
        echo "[警告] ${HY_DOMAIN} 当前解析到 ${RESOLVED_IP}，与本机出口 IP ${CURR_IP} 不一致，证书签发将失败！"
        read -p "是否仍要继续？[y/N] " go_on
        [ "$go_on" = "y" ] || exit 1
    fi
fi

echo "=== 1. 系统更新与基础依赖安装 ==="
apt update -y && apt install -y curl wget gnupg sed ufw openssl

echo "=== 2. 配置防火墙策略 (使用 UFW 兼容 Debian 13) ==="
# 默认允许所有流出，拒绝所有流入
ufw default deny incoming
ufw default allow outgoing

# 放行必要端口：80/tcp 用于 ACME HTTP-01 校验，443/udp 为 Hysteria QUIC 端口
# （443 仅 UDP，TCP 流量不存在，无需放行）
ufw allow 80/tcp
ufw allow 443/udp
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

# QUIC / UDP 缓冲区优化
# Hysteria 官方建议值：低于该值时高带宽长肥管道会被内核缓冲区卡住
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

# 应用所有 sysctl 配置（包括 sysctl.d 目录下的新文件）
sysctl --system

echo "=== 4. 安装 Docker (兼容 Debian 13 trixie) ==="
if ! command -v docker &> /dev/null; then
    # 使用官方一键脚本，能够自动识别 trixie 源，若无匹配则会自动安全降级到 bookworm 源
    curl -fsSL https://get.docker.com | sh
fi

# 生成连接密码（32 位 hex，足够抵抗暴力猜测，无需人工记忆）
HY_PASSWORD=$(openssl rand -hex 16)

echo "=== 5. 部署 Hysteria2 服务端到 /opt/hysteria ==="
mkdir -p /opt/hysteria
cd /opt/hysteria

# acme.certDir 必须挂载出来：否则容器重建后证书丢失，重新签发容易触发 Let's Encrypt 频率限制
cat > config.yaml <<EOF
listen: :443

acme:
  domains:
    - ${HY_DOMAIN}
  email: ${HY_EMAIL}
  certDir: /acme

auth:
  type: password
  password: ${HY_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${HY_MASQ}
    rewriteHost: true
EOF

cat > docker-compose.yml <<EOF
services:
  hysteria:
    image: tobyxdd/hysteria:latest
    container_name: hysteria-server
    restart: unless-stopped
    # host 网络保证 Hysteria 拿到真实客户端 IP（QUIC 无代理解法），
    # 且 ACME 自带的 80 端口 HTTP 校验监听无需额外映射
    network_mode: host
    volumes:
      - ./config.yaml:/etc/hysteria/config.yaml:ro
      - ./acme:/acme
    command: server -c /etc/hysteria/config.yaml
EOF

docker compose up -d

# 等待首次 ACME 签发完成，失败说明域名解析或防火墙有问题，当场暴露
echo "等待证书签发..."
sleep 10
if ! docker logs hysteria-server 2>&1 | grep -qE "server is up and running|listening"; then
    echo "[警告] 未在日志中确认启动成功，请手动执行：docker logs hysteria-server"
fi

echo "=== 6. 客户端配置信息 ==="

HY_URL="hysteria2://${HY_PASSWORD}@${CURR_IP}:443/?sni=${HY_DOMAIN}#hysteria-hy"

# 持久化到文件，方便 SSH 断开后找回
cat > /opt/hysteria/client-info.txt <<EOF
address  = ${CURR_IP}
port     = 443
password = ${HY_PASSWORD}
sni      = ${HY_DOMAIN}
masquerade = ${HY_MASQ}

客户端 config.yaml（二选一，URL 与 yaml 等效）:
server: ${CURR_IP}:443
auth: ${HY_PASSWORD}
tls:
  sni: ${HY_DOMAIN}

hysteria2 URL:
${HY_URL}
EOF

echo "服务端文件已写入 /opt/hysteria ，客户端信息已保存到 /opt/hysteria/client-info.txt"
echo ""
echo "${HY_URL}"

echo "=== 7. SSH 端口安全加固 ==="
if [ "$CURR_SSH_PORT" = "22" ]; then
    echo "检测到当前 SSH 端口为默认的 22。"
    read -p "是否想将 SSH 端口修改为 $SSH_PORT ？[y/N] " yn
    case $yn in
        [Yy])
            # 先放行新端口，再动 SSH 配置，顺序不能反
            ufw allow "$SSH_PORT"/tcp

            # 新端口若已被占用则放弃修改，避免重启后 SSH 起不来
            if ss -tln | grep -q ":$SSH_PORT "; then
                echo "[失败] 端口 $SSH_PORT 已被占用，跳过修改。"
            else
                # Debian 13 的 sshd_config 顶部 Include 了 sshd_config.d 目录，
                # 且 sshd 对 Port 取"第一个出现的值"，因此 drop-in 文件优先级最高、最可靠
                if grep -qE "^\s*Include\s+/etc/ssh/sshd_config.d" /etc/ssh/sshd_config; then
                    echo "Port $SSH_PORT" > /etc/ssh/sshd_config.d/00-port.conf
                elif grep -q "^#Port 22" /etc/ssh/sshd_config; then
                    sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
                elif grep -q "^Port " /etc/ssh/sshd_config; then
                    sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
                else
                    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
                fi

                # 配置语法校验通过才重启，防止改错把自己锁在门外
                if sshd -t 2>/dev/null; then
                    systemctl restart sshd
                    echo "[成功] SSH 端口已修改为 $SSH_PORT。请务必新开一个终端窗口测试连接，切勿直接关闭当前窗口！"
                else
                    echo "[失败] sshd 配置校验未通过，已放弃重启，请手动检查 /etc/ssh/ 配置。"
                fi
            fi
            ;;
        *)
            echo "已跳过修改 SSH 端口。"
            ;;
    esac
else
    echo "当前 SSH 端口为 $CURR_SSH_PORT（非默认 22），无需修改。"
fi
