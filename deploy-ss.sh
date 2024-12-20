#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-ss.sh)

# Modify the following parameters:
#PORT=random
METHOD=aes-256-gcm
#PASSWORD=random
PLUGIN="./v2ray-plugin"
PLUGIN_OPTS="server;host=apple.com"
#SERVICE_NAME="ss-server"
#SSH_PORT=random
#VNSTAT_PORT=
KCPTUN_PORT_START=11111
KCPTUN_PORT_END=11122
CHISEL_PORT=3110

if [ "$PORT" == "" ]; then
  PORT=$(shuf -i 2000-20000 -n 1)
fi
if [ "$PORT_UDPSPEEDER" == "" ]; then
  PORT_UDPSPEEDER=$(shuf -i 2000-20000 -n 1)
fi
if [ "$PORT_UDP2RAW" == "" ]; then
  PORT_UDP2RAW=$(shuf -i 2000-20000 -n 1)
fi
if [ "$METHOD" == "" ]; then
  METHOD=aes-256-gcm
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
if [ "$VNSTAT_PORT" == "" ]; then
  VNSTAT_PORT=$(shuf -i 2000-20000 -n 1)
fi

apt update -y
apt install -y curl cron

HLST="\033[0;37m\033[41m"
HLED="\033[0m"
CURR_IP=$(curl -s https://api.ipify.org)
CURR_SSH_PORT=${SSH_CLIENT##* }

# install iptables
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt install -y iptables iptables-persistent

iptables -P INPUT ACCEPT
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -P INPUT DROP
iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
iptables -A INPUT -p udp --dport $PORT -j ACCEPT
iptables -A INPUT -p udp --dport $PORT_UDPSPEEDER -j ACCEPT
iptables -A INPUT -p tcp --dport $PORT_UDP2RAW -j ACCEPT
iptables -A INPUT -p udp --dport $PORT_UDP2RAW -j ACCEPT
iptables -A INPUT -p tcp --dport $VNSTAT_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $KCPTUN_PORT_START:$KCPTUN_PORT_END -j ACCEPT
iptables -A INPUT -p tcp --dport $CHISEL_PORT -j ACCEPT

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
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor >/usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io

# deploy ss
echo "deploy ss..."
service --status-all | grep -Fq "$SERVICE_NAME"

cat >/etc/udp2raw.conf <<EOF
-s
# Listen address
-l 0.0.0.0:2012
# Remote address
-r 127.0.0.1:2011
-k $PASSWORD
--raw-mode faketcp
--lower-level auto
EOF

cat >/etc/udpspeeder.conf <<EOF
-s
-l 0.0.0.0:2011
-r 127.0.0.1:2001
-f 2:1,4:2,10:3,20:4
-q 20
--timeout 8
-k $PASSWORD
EOF

cat >/etc/kcptun_server.conf <<EOF
{
    "listen": ":$KCPTUN_PORT_START-$KCPTUN_PORT_END",
    "target": "127.0.0.1:2001",
    "key": "$PASSWORD",
    "crypt": "none",
    "mode": "fast",
    "mtu": 1196,
    "sndwnd": 128,
    "rcvwnd": 512,
    "datashard": 10,
    "parityshard": 3,
    "dscp": 46,
    "nocomp": true,
    "acknodelay": false,
    "nodelay": 1,
    "interval": 40,
    "resend": 2,
    "nc": 1,
    "sockbuf": 4194304,
    "smuxver": 2,
    "smuxbuf": 4194304,
    "streambuf": 1048576,
    "keepalive": 10,
    "pprof":false,
    "quiet":false,
    "tcp":false
}
EOF

cat >/etc/chisel.conf <<EOF
server -p 3110
EOF

# auto update
cat >/opt/auto-update.sh <<EOF
#!/usr/bin/env bash
set -e
SCRIPT_DIR=\$(
    cd \$(dirname \${BASH_SOURCE[0]})
    pwd
)

BASE_IMAGE="shadowsocks-rust:stable"
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
        docker rm -f \$im
        \$SCRIPT_DIR/run.sh

        docker image prune -f
    else
        echo "\$IMAGE up to date"
    fi
done
EOF

cat >/opt/run.sh <<EOF
BASE_IMAGE="shadowsocks-rust:stable"
REGISTRY="lostos"
SERVICE_NAME="$SERVICE_NAME"
IMAGE="\$REGISTRY/\$BASE_IMAGE"

docker run -d --name="\$SERVICE_NAME" \\
  --restart=always \\
  -p $PORT:2001/tcp \\
  -p $PORT:2001/udp \\
  -p $PORT_UDPSPEEDER:2011/udp \\
  -p $PORT_UDP2RAW:2012/tcp \\
  -p $PORT_UDP2RAW:2012/udp \\
  -p $CHISEL_PORT:3110/tcp \\
  -p $VNSTAT_PORT:8080/tcp \\
  -p $KCPTUN_PORT_START-$KCPTUN_PORT_END:$KCPTUN_PORT_START-$KCPTUN_PORT_END/udp \\
  -v /etc/udp2raw.conf:/ss/udp2raw.conf \\
  -v /etc/udpspeeder.conf:/ss/udpspeeder.conf \\
  -v /etc/kcptun_server.conf:/ss/kcptun_server.conf \\
  -v /etc/chisel.conf:/ss/chisel.conf \\
  -v /mnt/ss-server:/data \\
  \$IMAGE \\
  server \\
  -s "0.0.0.0:2001" \\
  -m "$METHOD" \\
  -k "$PASSWORD" \\
  -U \\
  --plugin "$PLUGIN" \\
  --plugin-opts "$PLUGIN_OPTS"
EOF

chmod +x /opt/auto-update.sh /opt/run.sh
crontab -l >mycron
sed -i '/\/opt\/auto-update.sh/d' ./mycron
echo "0 3 * * * /opt/auto-update.sh" >>mycron
crontab mycron
rm mycron

docker rm -f "$SERVICE_NAME"
/opt/run.sh

echo "install successs."
echo -e "          ip: $HLST$CURR_IP$HLED"
echo -e "        port: $HLST$PORT$HLED"
echo -e "port udp2raw: $HLST$PORT_UDP2RAW$HLED"
echo -e " port vnstat: $HLST$VNSTAT_PORT$HLED"
echo -e " port kcptun: $HLST$KCPTUN_PORT_START-$KCPTUN_PORT_END$HLED"
echo -e "      method: $HLST$METHOD$HLED"
echo -e "    password: $HLST$PASSWORD$HLED"
echo -e "      plugin: $HLST$PLUGIN$HLED"
echo -e " plugin opts: $HLST$PLUGIN_OPTS$HLED"

read -p "Do you want to modify the SSH port to $SSH_PORT now?[Y/n]" yn
case $yn in
[Yy] | "")
  sed -i "/Port/c\Port $SSH_PORT" /etc/ssh/sshd_config
  systemctl restart sshd
  iptables -D INPUT -p tcp --dport $CURR_SSH_PORT -j ACCEPT
  iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
  echo -e "SSH port has been changed to $HLST$SSH_PORT$HLED."
  service netfilter-persistent save
  ;;
[Nn]) ;;
esac
