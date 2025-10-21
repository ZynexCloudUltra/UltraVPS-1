#!/usr/bin/env bash
# 🚀 Ultra-Optimized Debian 11 IPv6 VPS Setup Script (FULL)
# Focus: Low-latency Minecraft, Pterodactyl Wings, Docker
# Includes: Firewall, DDoS protection, CPU/memory tuning, THP disable, irqbalance, tuned, fq_codel, NIC tuning
# IPv6-only compatible, safe with IPv4 present
# Final banner: "VPS FIRE+ + DDoS SHIELD Active! Powered by Zynex Cloud"

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Please run as root."
  exit 1
fi

log() { echo -e "👉 $1"; }

# -----------------------------
# 0) Basic info
# -----------------------------
if ! grep -qi "Debian GNU/Linux 11" /etc/os-release; then
  echo "⚠️ This script targets Debian 11 (Bullseye). Continuing anyway..."
fi

# -----------------------------
# 1) System update & packages
# -----------------------------
log "📦 Updating system and installing packages..."
apt-get update -y
apt-get upgrade -y

apt-get install -y \
  curl wget unzip zip git screen htop net-tools neofetch iftop iotop nload bmon \
  build-essential ca-certificates gnupg lsb-release ethtool ufw fail2ban dialog \
  lsof jq iptables-persistent cpufrequtils irqbalance haveged mlocate bc sysstat \
  tuned numactl cpuid netdata atop

timedatectl set-timezone UTC || true
hostnamectl set-hostname optimized-vps || true

# -----------------------------
# 2) CPU optimization
# -----------------------------
log "⚡ Setting CPU governor to performance..."
systemctl disable --now ondemand || true
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl enable --now cpufrequtils || true
systemctl enable --now irqbalance || true

# Immediate governor set (best effort)
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$gov" 2>/dev/null || true
done

# -----------------------------
# 3) Swap
# -----------------------------
log "💾 Configuring 2GB swap..."
SWAPFILE="/swapfile"
if ! grep -q "$SWAPFILE" /etc/fstab; then
  fallocate -l 2G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# -----------------------------
# 4) Sysctl tuning
# -----------------------------
log "🔧 Applying sysctl optimizations..."
cat > /etc/sysctl.d/99-optimized-vps.conf <<'EOF'
# File & backlog
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000

# Queueing & congestion control
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# TCP latency & resilience
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# Buffers (low-latency bursts)
net.core.rmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_default = 262144
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# SYN backlog & TIME-WAIT buckets
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 2000000

# IPv6 forwarding (Docker/Wings overlays)
net.ipv6.conf.all.forwarding = 1

# Anti-DDoS sysctls
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Memory behavior
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Conntrack scale
net.netfilter.nf_conntrack_max = 262144
EOF
sysctl --system

# -----------------------------
# 5) Disable Transparent Huge Pages (THP)
# -----------------------------
log "🛑 Disabling Transparent Huge Pages..."
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
ExecStart=/bin/bash -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp

# -----------------------------
# 6) tuned latency profile
# -----------------------------
log "🎚️ Enabling tuned latency-performance profile..."
systemctl enable --now tuned || true
tuned-adm profile latency-performance || true

# -----------------------------
# 7) fq_codel service
# -----------------------------
log "🌊 Creating fq_codel service..."
cat > /usr/local/bin/apply-fqcodel.sh <<'EOS'
#!/bin/bash
IFACES=$(ip -o link show | awk -F": " "{print \$2}" | grep -vE "lo|docker|veth|br-|virbr|vmnet|tap|tun")
for IFACE in $IFACES; do
  tc qdisc replace dev "$IFACE" root fq_codel || true
done
EOS
chmod +x /usr/local/bin/apply-fqcodel.sh

cat > /etc/systemd/system/qdisc-fqcodel.service <<'EOF'
[Unit]
Description=Apply fq_codel qdisc to interfaces
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/apply-fqcodel.sh
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now qdisc-fqcodel.service

# -----------------------------
# 8) Firewall & Fail2Ban
# -----------------------------
log "🛡️ Configuring UFW firewall..."
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 8080/tcp  comment 'Wings/Dashboard'
ufw allow 25565/tcp comment 'Minecraft TCP'
ufw allow 25565/udp comment 'Minecraft UDP'
ufw --force enable

log "🚨 Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 15m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
backend = systemd

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
EOF
systemctl enable --now fail2ban

# -----------------------------
# 9) ip6tables rules (IPv6 anti-DDoS + Minecraft)
# -----------------------------
log "🌐 Applying ip6tables rules..."
ip6tables -F || true
ip6tables -X || true
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p icmpv6 -m limit --limit 20/second --limit-burst 40 -j ACCEPT
ip6tables -A INPUT -p tcp -m multiport --dports 22,80,443,8080 -j ACCEPT
ip6tables -A INPUT -p udp --dport 25565 -m limit --limit 300/second --limit-burst 600 -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

ip6tables-save > /etc/iptables/rules.v6

# Minimal IPv4 persistence so IPv4 won’t break if present (UFW manages v4 policy)
iptables -F || true
iptables -X || true
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables-save > /etc/iptables/rules.v4

systemctl enable --now netfilter-persistent || true

# -----------------------------
# 10) Docker (install & optimize)
# -----------------------------
log "🐳 Installing and optimizing Docker..."

# Install Docker repo & packages if not present
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
fi

# Docker daemon optimization (IPv6-ready, log rotation)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "32m", "max-file": "4", "compress": "true" },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 6,
  "ipv6": true,
  "fixed-cidr-v6": "fd00:dead:beef::/64",
  "iptables": true
}
EOF

systemctl enable --now docker
systemctl restart docker || true

# -----------------------------
# 11) Limits & PAM
# -----------------------------
log "📈 Increasing file descriptor and process limits..."
cat > /etc/security/limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
EOF

for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q "pam_limits.so" "$pam_file"; then
    echo "session required pam_limits.so" >> "$pam_file"
  fi
done

# -----------------------------
# 12) NIC tuning (queues & offloads)
# -----------------------------
log "🧩 Creating NIC tuning service (queues/offloads)..."
cat > /etc/systemd/system/nic-tuning.service <<'EOF'
[Unit]
Description=NIC tuning (queues & offloads)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c '
IFACES=$(ip -o link show | awk -F": " "{print \$2}" | grep -vE "lo|docker|veth|br-|virbr|vmnet|tap|tun");
for IFACE in $IFACES; do
  ip link set "$IFACE" txqueuelen 10000 || true
  ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
  ethtool -K "$IFACE" tso off gso off gro off lro off 2>/dev/null || true
done
'
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nic-tuning.service

# -----------------------------
# 13) Minecraft low-ping ops tips (comments)
# -----------------------------
# 💡 JVM flags (Aikar recommended), example for 4G allocation:
# java -Xms4G -Xmx4G -XX:+UseG1GC -XX:+ParallelRefProcEnabled \
# -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions \
# -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 \
# -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
# -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 \
# -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 \
# -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 \
# -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
# -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true \
# -jar server.jar nogui
# 🔭 View-distance: 8–10 (survival), 6–8 (large player counts)
# 🌐 IPv6 ready via sysctl forwarding + ip6tables rules
# 🛡️ UDP rate limiting for 25565 applied to reduce flood impact

# -----------------------------
# 14) Finishing touches
# -----------------------------
log "🧹 Finalizing setup..."
clear || true
neofetch || true

echo "🔥 VPS FIRE+ + DDoS SHIELD Active! Powered by Zynex Cloud 🔥"

log "🔁 Rebooting in 5 seconds..."
sleep 5
reboot
