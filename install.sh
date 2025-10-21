#!/bin/bash
# =========================================================
# Author: Zynex Cloud AI
# Version: 4.0 (Next-Gen Defense)
# =========================================================

echo ">>> 🧠 Initializing VPS FIRE+ Defense Engine..."

# --- Basic system update ---
apt update -y && apt upgrade -y && apt autoremove -y && apt clean

# --- Install core packages ---
echo ">>> ⚙️ Installing core tools..."
apt install -y curl wget unzip zip git screen htop net-tools neofetch iftop iotop nload bmon build-essential ca-certificates gnupg lsb-release ethtool ufw fail2ban dialog lsof jq iptables-persistent

# --- Timezone & hostname fix ---
timedatectl set-timezone UTC
hostnamectl set-hostname optimized-vps

# --- CPU performance mode ---
echo ">>> 💨 Enabling CPU Turbo Mode..."
apt install -y cpufrequtils
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl disable ondemand >/dev/null 2>&1
systemctl enable cpufrequtils >/dev/null 2>&1
systemctl start cpufrequtils >/dev/null 2>&1

# --- Swap optimization ---
echo ">>> 🧮 Setting up optimized swap..."
swapoff -a
dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" | tee -a /etc/fstab

# --- Sysctl performance & DDoS protection ---
echo ">>> ⚡ Applying kernel, network, and anti-DDoS tweaks..."
cat <<EOF > /etc/sysctl.d/99-vpsfireplus.conf
# --- VPS FIRE+ Core Performance ---
fs.file-max = 4194304
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# --- TCP/IP Performance + Protection ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_no_metrics_save = 1

# --- Anti-DDoS / Rate Limits ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- Memory & Disk Tweaks ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

sysctl --system

# --- Enable BBR (low ping) ---
modprobe tcp_bbr
echo "tcp_bbr" | tee -a /etc/modules-load.d/modules.conf

# --- Disable useless services ---
echo ">>> 🧹 Cleaning background load..."
for service in avahi-daemon bluetooth cups rpcbind systemd-resolved; do
  systemctl disable --now $service 2>/dev/null || true
done

# --- Security Layer (UFW + Fail2Ban + iptables) ---
echo ">>> 🛡️ Enabling Advanced Firewall + Fail2Ban..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80
ufw allow 443
ufw allow 8080
ufw --force enable

# --- iptables DDoS protection ---
echo ">>> ⚔️ Installing Anti-DDoS Rules..."
iptables -F
iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
iptables -A INPUT -f -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 3 -j DROP
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p udp --dport 25565 -m limit --limit 50/second --limit-burst 100 -j ACCEPT
iptables -A INPUT -p udp --dport 25565 -j DROP
iptables-save > /etc/iptables/rules.v4

systemctl enable netfilter-persistent
netfilter-persistent save

# --- Extend Fail2Ban ---
cat <<EOF > /etc/fail2ban/jail.d/custom-ddos.conf
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 300
bantime = 1800

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 5
EOF

systemctl restart fail2ban

# --- Docker optimization ---
echo ">>> 🐳 Optimizing Docker engine..."
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "max-concurrent-downloads": 20,
  "max-concurrent-uploads": 20,
  "storage-driver": "overlay2"
}
EOF
systemctl restart docker 2>/dev/null || true

# --- File & process limits ---
echo ">>> 🔧 Increasing process & file limits..."
cat <<EOF >> /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
ulimit -n 1048576

# --- Network card optimization ---
echo ">>> 🚀 Boosting network interface..."
for i in $(ls /sys/class/net | grep -v lo); do
  ethtool -G $i rx 4096 tx 4096 2>/dev/null
  ethtool -K $i tso off gso off gro off 2>/dev/null
done

# --- Visual indicator ---
clear
neofetch
echo -e "\n🛡️ VPS OPTIMIZED!"
echo "🔥 Your server is now tuned for extreme performance + protection"
echo "⚡ Ready for Pterodactyl, Minecraft, Cloudflare, and Wings"
echo "🔄 Rebooting to finalize..."

sleep 5
reboot
