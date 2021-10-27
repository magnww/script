#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-ss.sh)

# Modify the following parameters:
#PORT=random
METHOD=chacha20-ietf-poly1305
#PASSWORD=random
PLUGIN="./v2ray-plugin"
PLUGIN_OPTS="server;host=apple.com"
#SERVICE_NAME="ss-server"
#SSH_PORT=random

if [ "$PORT" == "" ]; then
  PORT=$(shuf -i 2000-20000 -n 1)
fi
if [ "$METHOD" == "" ]; then
  METHOD=chacha20-ietf-poly1305
fi
if [ "$PASSWORD" == "" ]; then
  PASSWORD=$(echo $RANDOM | md5sum | head -c 20)
fi
if [ "$PLUGIN" == "" ]; then
  PLUGIN="./v2ray-plugin"
fi
if [ "$PLUGIN_OPTS" == "" ]; then
  PLUGIN_OPTS="server;host=apple.com"
fi
if [ "$SERVICE_NAME" == "" ]; then
  SERVICE_NAME=ss-server
fi
if [ "$SSH_PORT" == "" ]; then
  SSH_PORT=$(shuf -i 2000-20000 -n 1)
fi

apt update -y
apt install -y sudo curl

HLST="\033[0;37m\033[41m"
HLED="\033[0m"
CURR_IP=$(curl -s https://api.ipify.org)
CURR_SSH_PORT=${SSH_CLIENT##* }

# install iptables
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
apt install -y iptables iptables-persistent

iptables -P INPUT ACCEPT
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -P INPUT DROP
iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
iptables -A INPUT -p udp --dport $PORT -j ACCEPT

if [ "$CURR_SSH_PORT" != "" ]; then
  iptables -A INPUT -p tcp --dport $CURR_SSH_PORT -j ACCEPT
fi

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

service netfilter-persistent save

# enable tcp bbr
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf 
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p

# install docker
apt remove -y docker docker-engine docker.io containerd runc

echo "install docker..."
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor >/usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io

# deploy ss
echo "deploy ss..."
service --status-all | grep -Fq "$SERVICE_NAME"

docker rm -f "$SERVICE_NAME"
docker create --name="$SERVICE_NAME" \
  --restart=always \
  -p $PORT:$PORT/tcp \
  -p $PORT:$PORT/udp \
  lostos/shadowsocks-rust \
  -s "0.0.0.0:$PORT" \
  -m "$METHOD" \
  -k "$PASSWORD" \
  --plugin "$PLUGIN" \
  --plugin-opts "$PLUGIN_OPTS"

cat >/etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=docker compose
Requires=docker.service
After=docker.service

[Service]
Type=simple
WorkingDirectory=/opt
ExecStart=/usr/bin/docker start $SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME"; then
  systemctl daemon-reload
fi
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# auto update
cat >/opt/auto-update.sh <<EOF
#!/usr/bin/env bash
set -e
BASE_IMAGE="shadowsocks-rust"
REGISTRY="lostos"
SERVICE_NAME="$SERVICE_NAME"
IMAGE="\$REGISTRY/\$BASE_IMAGE"

cd \$(dirname \$0)
CID=\$(docker ps | grep \$IMAGE | awk '{print \$1}')
docker pull \$IMAGE

for im in \$CID
do
    LATEST=\$(docker inspect --format "{{.Id}}" \$IMAGE)
    RUNNING=\$(docker inspect --format "{{.Image}}" \$im)
    NAME=\$(docker inspect --format '{{.Name}}' \$im | sed "s/\\///g")
    echo "Latest:" \$LATEST
    echo "Running:" \$RUNNING
    if [ "\$RUNNING" != "\$LATEST" ];then
        echo "upgrading \$IMAGE"
        systemctl stop \$SERVICE_NAME
        docker-compose up --no-start --force-recreate
        systemctl start \$SERVICE_NAME
        docker image prune -f
    else
        echo "\$IMAGE up to date"
    fi
done
EOF
chmod +x /opt/auto-update.sh
crontab -l >mycron
sed -i '/\/opt\/auto-update.sh/d' ./mycron
echo "0 3 * * * /opt/auto-update.sh" >>mycron
crontab mycron
rm mycron

echo "install successs."
echo -e "         ip: $HLST$CURR_IP$HLED"
echo -e "       port: $HLST$PORT$HLED"
echo -e "     method: $HLST$METHOD$HLED"
echo -e "   password: $HLST$PASSWORD$HLED"
echo -e "     plugin: $HLST$PLUGIN$HLED"
echo -e "plugin opts: $HLST$PLUGIN_OPTS$HLED"

while true; do
  read -p "Do you want to modify the SSH port to $SSH_PORT now?[Y/n]" yn
  case $yn in
  [Yy] | "")
    sed -i "/Port/c\Port $SSH_PORT" /etc/ssh/sshd_config
    systemctl restart sshd
    iptables -D INPUT -p tcp --dport $CURR_SSH_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
    echo -e "SSH port has been changed to $HLST$SSH_PORT$HLED."
    service netfilter-persistent save
    break
    ;;
  [Nn]) break ;;
  esac
done
