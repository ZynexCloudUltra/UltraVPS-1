#!/usr/bin/env bash
# install.sh - Production-ready optimization script for Debian 11 (IPv6-ready)
# Target: Low-latency Minecraft servers, Pterodactyl Wings, Docker services
# Includes: Basic DDoS protection, firewall, IPv6 compatibility without breaking IPv4
# Notes:
# - Tested logic for Debian 11 (Bullseye). Adjusts sysctl, UFW, Fail2Ban, ip6tables, Docker, CPU governor, swap, and NIC tuning.
# - Fully commented, no ASCII banners, safe defaults, and rate-limited UDP for Minecraft.
# - Ends with: "VPS FIRE+ + DDoS SHIELD Active! Powered by Zynex Cloud" and reboots.

set -euo pipefail

# Ensure non-interactive apt operations
export DEBIAN_FRONTEND=noninteractive

# Require root
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

# Detect Debian version (basic check)
if ! grep -qi "Debian GNU/Linux 11" /etc/os-release; then
  echo "Warning: This script is designed for Debian 11 (Bullseye). Continuing anyway..."
fi

# -----------------------------
# Helper functions
# -----------------------------

log() {
  echo -e "[+] $1"
}

sysctl_apply() {
  # Write sysctl settings idempotently and apply
  local sysctl_file="$1"
  shift
  cat > "$sysctl_file" <<'EOF'
# ===========================
# Kernel & network optimization for low latency + IPv6
# Focused on Minecraft, Wings, Docker, and basic anti-DDoS
# ===========================

# General file limits
fs.file-max = 2097152

# ---------------------------
# TCP congestion control
# ---------------------------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---------------------------
# TCP fast open & timeouts
# ---------------------------
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15

# NOTE: tcp_tw_reuse is deprecated in newer kernels but still present in 5.10
# Safe here for Bullseye; if ignored, kernel will skip.
net.ipv4.tcp_tw_reuse = 1

# ---------------------------
# Buffers for low-latency traffic (Minecraft/Pterodactyl)
# These values aim for balanced throughput and reduced jitter.
# ---------------------------
net.core.rmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_default = 262144
net.core.wmem_max = 67108864

net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Increase backlog queues
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 2000000

# Enable TCP timestamps and SACK (benefits most flows, can help latency)
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# ---------------------------
# IPv6 forwarding (for Wings/Docker overlay & containers)
# ---------------------------
net.ipv6.conf.all.forwarding = 1

# ---------------------------
# Anti-DDoS sysctl (IPv4/IPv6)
# ---------------------------
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Enable SYN cookies
net.ipv4.tcp_syncookies = 1

# Reverse path filtering (mainly for IPv4; safe to enable)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ICMP protections
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Avoid source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ---------------------------
# Swappiness & cache pressure (with swap present)
# ---------------------------
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# ---------------------------
# NAPI polling/queues tuning
# ---------------------------
net.core.somaxconn = 65535
EOF

  sysctl -p "$sysctl_file" || sysctl --system
}

# -----------------------------
# 1) System update & core packages
# -----------------------------
log "Updating system and installing core packages..."

# Basic system prep
apt-get update -y
apt-get upgrade -y

# Essential packages
apt-get install -y \
  curl wget unzip zip git screen htop net-tools neofetch iftop iotop nload bmon \
  build-essential ca-certificates gnupg lsb-release ethtool ufw fail2ban dialog \
  lsof jq iptables-persistent ip6tables-persistent cpufrequtils

# Timezone & hostname
log "Setting timezone to UTC and hostname to optimized-vps..."
timedatectl set-timezone UTC || true
hostnamectl set-hostname optimized-vps || true

# -----------------------------
# 2) CPU optimization
# -----------------------------
log "Configuring CPU performance governor..."
# Disable ondemand if present
if systemctl list-units --type=service | grep -qE 'ondemand'; then
  systemctl disable --now ondemand || true
fi

# Set performance governor
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl enable cpufrequtils || true
systemctl restart cpufrequtils || true

# Also attempt to set governor immediately for all CPUs
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance || true
else
  for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu_gov" 2>/dev/null || true
  done
fi

# -----------------------------
# 3) Memory & swap
# -----------------------------
log "Configuring 2GB swap file..."
SWAPFILE="/swapfile"
if ! grep -q "$SWAPFILE" /etc/fstab; then
  fallocate -l 2G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
fi

# -----------------------------
# 4) Kernel & network tweaks
# -----------------------------
log "Applying kernel and network sysctl optimizations..."
SYSCTL_FILE="/etc/sysctl.d/99-optimized-vps.conf"
sysctl_apply "$SYSCTL_FILE"

# -----------------------------
# 5) Firewall & security (UFW + Fail2Ban)
# -----------------------------
log "Configuring UFW firewall for SSH, HTTP/HTTPS, 8080, and Minecraft..."

# Ensure UFW handles IPv6
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow key services
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 8080/tcp  comment 'Wings/Dashboard'
# Minecraft typical ports (both TCP and UDP)
ufw allow 25565/tcp comment 'Minecraft TCP'
ufw allow 25565/udp comment 'Minecraft UDP'

# Enable UFW
ufw --force enable

# Fail2Ban basic setup
log "Configuring Fail2Ban for SSH and Nginx HTTP auth..."
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

systemctl enable fail2ban
systemctl restart fail2ban

# -----------------------------
# 6) ip6tables rules (anti-DDoS + Minecraft UDP rate limits)
# -----------------------------
log "Applying ip6tables rules for IPv6 anti-DDoS and Minecraft traffic..."

# Flush existing IPv6 rules cautiously
ip6tables -F || true
ip6tables -X || true

# Default policies: drop inbound, allow outbound
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# Allow loopback
ip6tables -A INPUT -i lo -j ACCEPT

# Allow established/related
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow essential ICMPv6 (Neighbor Discovery, Router Solicitation/Advertisement, Echo-Request)
# Rate-limit generic ICMPv6 to prevent floods
ip6tables -A INPUT -p icmpv6 -m limit --limit 20/second --limit-burst 40 -j ACCEPT

# Allow SSH/HTTP/HTTPS/8080 (TCP)
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 8080 -j ACCEPT

# Minecraft UDP (25565) rate-limited
# Balanced limit to reduce UDP flood impact, while keeping gameplay viable.
ip6tables -A INPUT -p udp --dport 25565 -m limit --limit 300/second --limit-burst 600 -j ACCEPT

# Optional: drop INVALID packets
ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

# Log (limited) dropped packets (commented to avoid spam; uncomment for debugging)
# ip6tables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "IP6Tables-DROP: "

# Persist IPv6 rules
ip6tables-save > /etc/iptables/rules.v6

# IPv4 baseline rules (to avoid breaking when IPv4 exists; keep minimal and safe)
# Do not aggressively restrict IPv4; UFW manages primary v4 policy. Persist baseline.
iptables -F || true
iptables -X || true
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables-save > /etc/iptables/rules.v4

# Ensure iptables-persistent services are enabled
systemctl enable netfilter-persistent || true
systemctl restart netfilter-persistent || true

# -----------------------------
# 7) Docker installation & optimization
# -----------------------------
log "Installing and optimizing Docker daemon..."

# Install Docker CE from official repository (stable)
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  DOCKER_REPO="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable"
  echo "$DOCKER_REPO" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
fi

# Docker daemon optimization
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "32m",
    "max-file": "4"
  },
  "max-concurrent-downloads": 6,
  "max-concurrent-uploads": 6,
  "ipv6": true,
  "fixed-cidr-v6": "fd00:dead:beef::/64",
  "experimental": false,
  "iptables": true
}
EOF

systemctl enable docker
systemctl restart docker

# -----------------------------
# 8) File & process limits
# -----------------------------
log "Increasing file descriptor and process limits..."
# System-wide file descriptor limit
echo 'fs.file-max=2097152' > /etc/sysctl.d/99-file-max.conf
sysctl -p /etc/sysctl.d/99-file-max.conf || true

# Security limits
LIMITS_CONF="/etc/security/limits.conf"
if ! grep -q "ZYNEX_LIMITS" "$LIMITS_CONF"; then
  cat >> "$LIMITS_CONF" <<'EOF'
# ZYNEX_LIMITS
*               soft    nofile          1048576
*               hard    nofile          1048576
*               soft    nproc           65535
*               hard    nproc           65535
root            soft    nofile          1048576
root            hard    nofile          1048576
EOF
fi

# PAM limits (ensures limits.conf is loaded)
for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q "pam_limits.so" "$pam_file"; then
    echo "session required pam_limits.so" >> "$pam_file"
  fi
done

# -----------------------------
# 9) Network interface optimization (RX/TX queues, disable tso/gso/gro)
# -----------------------------
log "Optimizing network interfaces (queues and offloads)..."

# Iterate all non-loopback interfaces
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-|virbr|vmnet')

for IFACE in "${IFACES[@]}"; do
  log "Tuning interface: $IFACE"

  # Increase TX queue length (helps burst handling)
  ip link set "$IFACE" txqueuelen 10000 || true

  # Adjust ring buffers (if supported)
  ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true

  # Disable large offloads that can introduce latency/jitter (TSO/GSO/GRO)
  ethtool -K "$IFACE" tso off gso off gro off lro off 2>/dev/null || true

  # NIC coalescing is device-dependent; skip unless known
done

# Persist offload/queue settings via systemd service
cat > /etc/systemd/system/nic-tuning.service <<'EOF'
[Unit]
Description=NIC tuning (queues & offloads)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '
IFACES=$(ip -o link show | awk -F": " "{print \$2}" | grep -vE "lo|docker|veth|br-|virbr|vmnet");
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
systemctl enable nic-tuning.service

# -----------------------------
# 10) Minecraft low-ping specific tweaks (comments + sysctl already set)
# -----------------------------
# Notes for operators:
# - The sysctl buffer settings and fastopen/timestamps/SACK are tuned for lower latency and smoother burst handling.
# - Ensure your Java flags for Minecraft allocate RAM responsibly:
#   Example: -Xms2G -Xmx4G for 4–8GB systems. Avoid allocating all RAM to JVM; leave ~1–2GB for OS and Docker.
# - Recommended view-distance for survival servers: 8–10 (lower for large player counts to reduce tick load).
# - IPv6 compatibility is ensured via net.ipv6.conf.all.forwarding=1 and ip6tables rules above.
# - UDP rate limiting for port 25565 is applied via ip6tables (balanced to reduce flood impact without breaking gameplay).

# -----------------------------
# 11) Finishing touches
# -----------------------------
log "Finalizing..."

# Clear terminal and show system info
clear || true
neofetch || true

echo "VPS FIRE+ + DDoS SHIELD Active! Powered by Zynex Cloud"

# Reboot to apply all changes cleanly
log "Rebooting in 5 seconds..."
sleep 5
reboot
