#!/bin/bash
# BBRv3 using XanMod kernel (Optimized)

CYAN="\e[96m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
BLUE="\e[94m"
MAGENTA="\e[95m"
NC="\e[0m"

# Initial agreement
clear
echo -e "${CYAN}This script will:\n"
echo -e "- Install the XanMod kernel based on your CPU level"
echo -e "- Apply TCP-BBRv3 network optimizations via sysctl"
echo -e "- Require a reboot afterward"
echo -e "\n${YELLOW}Proceed? (y/n):${NC}"
read consent
[[ "$consent" != "y" && "$consent" != "Y" ]] && echo -e "${RED}Aborted by user.${NC}" && exit 1

echo -e "${GREEN}Initial check passed. Proceeding...${NC}"

# WSL check
grep -qiE 'microsoft|wsl' /proc/version && {
  echo -e "${RED}WSL or similar environment detected. This script requires a full Linux VPS with a modifiable kernel.${NC}"
  exit 1
}

# Kernel check
kernel_version=$(uname -r | cut -d- -f1)
if [ "$(printf '%s\n' "$kernel_version" "6.3" | sort -V | head -n1)" != "6.3" ]; then
  echo -e "${RED}Warning: Your current kernel version is ${kernel_version}. BBRv3 requires kernel 6.3 or newer.${NC}"
fi

# Check dependencies
for bin in gpg wget awk; do
  if ! command -v $bin >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing missing dependency: ${bin}${NC}"
    apt-get update && apt-get install -y $bin || {
      echo -e "${RED}Failed to install $bin. Aborting.${NC}"
      exit 1
    }
  fi
done

# check OS
. /etc/os-release
if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
  echo -e "${RED}Unsupported OS. Only Debian/Ubuntu supported.${NC}"
  exit 1
fi

ask_reboot() {
  echo ""
  echo -e "\n ${YELLOW}Reboot now? (Recommended) ${GREEN}[y/n]${NC}"
  echo ""
  read reboot
  case "$reboot" in
    [Yy]) systemctl reboot ;;
    *) return ;;
  esac
  exit
}

press_enter() {
  echo -e "\n ${RED}Press Enter to continue... ${NC}"
  read
}

logo() {
  echo -e "${CYAN}XanMod + BBRv3 Kernel Optimizer${NC}"
}

if [ "$EUID" -ne 0 ]; then
  echo -e "\n ${RED}This script must be run as root.${NC}"
  exit 1
fi

cpu_level() {
  echo -e "${YELLOW}Checking CPU capability...${NC}"
  cpu_info=$(awk '
    BEGIN {
      while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
      if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
      if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
      if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
      if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
      if (level > 0) { print "CPU supports x86-64-v" level; exit level + 1 }
      exit 1
    }')

  if [[ $cpu_info == "CPU supports x86-64-v"* ]]; then
    cpu_support_level=${cpu_info##*v}
    echo -e "${MAGENTA}Detected: ${GREEN}${cpu_info}${NC}"
  else
    echo -e "${RED}Unable to detect supported CPU level.${NC}"
    cpu_support_level=0
  fi
}

install_xanmod() {
  clear
  cpu_level
  echo ""
  echo -e "${YELLOW}Installing XanMod kernel...${NC}"
  cp /boot/grub/grub.cfg /boot/grub/grub.cfg.bak 2>/dev/null
  wget -qO - https://gitlab.com/afrd.gpg | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' > /etc/apt/sources.list.d/xanmod-release.list
  apt-get update

  case $cpu_support_level in
    1) apt-get install linux-xanmod-x64v1 -y ;;
    2) apt-get install linux-xanmod-x64v2 -y ;;
    3) apt-get install linux-xanmod-x64v3 -y ;;
    4) apt-get install linux-xanmod-x64v4 -y ;;
    *) echo -e "${RED}Unsupported CPU level.${NC}"; return 1 ;;
  esac

  latest_kernel=$(dpkg -l | grep xanmod | grep linux-image | awk '{print $2}')
  echo -e "${GREEN}Installed kernel: ${latest_kernel}${NC}"
  press_enter
  clear
  update-grub
}

uninstall_xanmod() {
  clear
  current_kernel=$(uname -r)

  if [[ $current_kernel == *-xanmod* ]]; then
    echo -e "${CYAN}Detected kernel: ${GREEN}${current_kernel}${NC}"
    for i in $(seq 1 4); do
      apt-get purge linux-xanmod-x64v$i -y
    done
    apt-get update && apt-get autoremove -y
    update-grub
    echo -e "${GREEN}Uninstall complete. Please reboot.${NC}"
  else
    echo -e "${RED}Not using XanMod kernel. Nothing to uninstall.${NC}"
  fi
}

reset_sysctl() {
  if [ -f /etc/sysctl.d/99-popcache.conf.bak ]; then
    mv /etc/sysctl.d/99-popcache.conf.bak /etc/sysctl.d/99-popcache.conf && sysctl -p
    echo -e "${GREEN}Sysctl restored to original.${NC}"
  else
    echo -e "${YELLOW}No backup sysctl config to restore.${NC}"
  fi
}

bbrv3() {
  clear
  echo -e "${YELLOW}Applying BBRv3 sysctl optimizations...${NC}"
  [ -f /etc/sysctl.d/99-popcache.conf ] && cp /etc/sysctl.d/99-popcache.conf /etc/sysctl.d/99-popcache.conf.bak
  cat <<EOL > /etc/sysctl.d/99-popcache.conf
# BBRv3 Optimization
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.default_qdisc = fq
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOL
  sysctl -p && echo -e "${GREEN}Sysctl applied.${NC}" || reset_sysctl
  lsmod | grep -q bbr || modprobe tcp_bbr
}

while true; do
  clear
  logo
  echo -e "${MAGENTA}System: ${GREEN}$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release)${NC}"
  echo -e "${MAGENTA}Kernel: ${GREEN}$(uname -r)${NC}"
  cpu_level
  echo ""
  echo -e "${GREEN}1)${NC} Install XanMod Kernel + BBRv3"
  echo -e "${GREEN}2)${NC} Uninstall XanMod Kernel"
  echo -e "${GREEN}3)${NC} Check Kernel & BBR Status"
  echo -e "${GREEN}E)${NC} Exit"
  echo ""
  echo -ne "${GREEN}Select an option: ${NC}"
  read choice

  case $choice in
    1) install_xanmod; bbrv3; ask_reboot ;;
    2) uninstall_xanmod; ask_reboot ;;
    3)
      clear
      echo -e "${YELLOW}Kernel & BBR Status${NC}"
      echo -e "Kernel version: $(uname -r)"
      echo -e "TCP congestion control: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
      echo -e "Default qdisc: $(sysctl net.core.default_qdisc | awk '{print $3}')"
      if lsmod | grep -q bbr; then
        echo -e "BBR module loaded (via lsmod): Yes"
      elif modinfo tcp_bbr 2>/dev/null; then
        echo -e "BBR module is built-in or available but not shown via lsmod"
      else
        echo -e "BBR not available on this kernel"
      fi
      press_enter
      ;;
    [Ee]) echo "Exiting..."; exit 0 ;;
    *) echo -e "${RED}Invalid input.${NC}" ;;
  esac

  press_enter
done
