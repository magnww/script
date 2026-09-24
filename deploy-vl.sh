#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-vl.sh) 

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

# 生成UUID
X_UUID=$(docker run --rm ghcr.io/xtls/xray-core uuid)

# 生成 Reality 密钥对
# 注意：新版 xray 输出 "PrivateKey:"，旧版为 "Private key:"，均用 $NF 取末尾值兼容
X25519_OUTPUT=$(docker run --rm ghcr.io/xtls/xray-core x25519)
X_PRIVATE_KEY=$(echo "$X25519_OUTPUT" | awk '/[Pp]rivate[ ]?[Kk]ey/ {print $NF}')
X_PUBLIC_KEY=$(echo "$X25519_OUTPUT" | awk '/[Pp]ublic[ ]?[Kk]ey/ {print $NF}')

# 解析失败立即退出，避免把空密钥写进配置
if [ -z "$X_PRIVATE_KEY" ] || [ -z "$X_PUBLIC_KEY" ]; then
    echo "x25519 密钥对生成失败，原始输出：$X25519_OUTPUT"
    exit 1
fi

# 生成 shortId（8 字节随机 hex）
X_SHORT_ID=$(openssl rand -hex 8)

# Reality 伪装目标
X_SNI="zozo.jp"

echo "=== 5. 部署 Xray 服务端到 /opt/xray ==="
mkdir -p /opt/xray
cd /opt/xray

cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${X_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${X_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${X_SNI}"
          ],
          "privateKey": "${X_PRIVATE_KEY}",
          "shortIds": [
            "${X_SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

cat > docker-compose.yml <<EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-server
    restart: unless-stopped
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    ports:
      - "443:443"
    command: run -config /etc/xray/config.json
EOF

docker compose up -d

echo "=== 6. 客户端配置信息 ==="

VLESS_URL="vless://${X_UUID}@${CURR_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${X_SNI}&fp=chrome&pbk=${X_PUBLIC_KEY}&sid=${X_SHORT_ID}&type=tcp#xray-vl"

# 持久化到文件，方便 SSH 断开后找回
cat > /opt/xray/client-info.txt <<EOF
address  = ${CURR_IP}
port     = 443
uuid     = ${X_UUID}
flow     = xtls-rprx-vision
publicKey= ${X_PUBLIC_KEY}
shortId  = ${X_SHORT_ID}
sni      = ${X_SNI}

vless URL:
${VLESS_URL}
EOF

echo "服务端文件已写入 /opt/xray ，客户端信息已保存到 /opt/xray/client-info.txt"
echo ""
echo "${VLESS_URL}"

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
