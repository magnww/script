#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/magnww/script/main/deploy-caddy.sh)

apt update -y

# install iptables
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt install -y iptables iptables-persistent

iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

service netfilter-persistent save

# enable tcp bbr
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf 
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf

# optimize TCP parameters
sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
echo "net.ipv4.tcp_slow_start_after_idle=0" >>/etc/sysctl.conf
echo "net.ipv4.tcp_notsent_lowat=16384" >>/etc/sysctl.conf
echo "net.ipv4.tcp_fastopen=0" >>/etc/sysctl.conf
sysctl -p

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

cat >/opt/caddy/Caddyfile <<EOF
{
  order forward_proxy before file_server
  acme_ca https://acme.zerossl.com/v2/DV90
}
:443, example.com {
  tls me@example.com
  forward_proxy {
    basic_auth user pass
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
EOF

cat >/opt/caddy/auto-update.sh <<EOF
#!/usr/bin/env bash
set -e
SCRIPT_DIR=\$(
    cd \$(dirname \${BASH_SOURCE[0]})
    pwd
)

BASE_IMAGE="caddy-naive"
REGISTRY="lostos"
SERVICE_NAME="caddy"
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

cat >/opt/caddy/run.sh <<EOF
BASE_IMAGE="caddy-naive"
REGISTRY="lostos"
SERVICE_NAME="caddy"
IMAGE="\$REGISTRY/\$BASE_IMAGE"

docker run -d --name="\$SERVICE_NAME" \\
    --restart=always \\
    -p 80:80/tcp \\
    -p 443:443/tcp \\
    -p 443:443/udp \\
    -v /opt/caddy/Caddyfile:/app/Caddyfile \\
    -v /var/www/html:/var/www/html \\
    \$IMAGE
EOF

chmod +x /opt/caddy/auto-update.sh /opt/caddy/run.sh
crontab -l >mycron
sed -i '/\/opt\/caddy\/auto-update.sh/d' ./mycron
echo "0 3 * * * /opt/caddy/auto-update.sh" >>mycron
crontab mycron
rm mycron

echo "The installation is complete."
echo "You need to edit the domain, email, username and password in /opt/caddy/Caddyfile."
echo "In addition, you need to put a website in /var/www/html"
