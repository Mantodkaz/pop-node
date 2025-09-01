#!/bin/bash
# Auto IRQ pinning
# Usage:
#   sudo ./irq-pin.sh                # auto, all NIC
#   IFACE=wlo1 sudo ./irq-pin.sh     # some interface

set -euo pipefail

: "${IFACE:=}"       # ex: IFACE=wlo1
: "${START_CORE:=1}" # start from CPU1 (avoid CPU0)

if [[ $EUID -ne 0 ]]; then echo "run as root"; exit 1; fi

total_cores=$(nproc)
core_idx=$START_CORE

# Pattern driver/device NIC: LAN + Wi-Fi
NIC_PAT='virtio|eth|enp|ens|eno|ixgbe|igb|i40e|ice|mlx5|r8169|tg3|atl|bnx2|iwlwifi|ath|rtw|mt76|brcmfmac|rtl8xxxu|rt2800'

# Builder mask hexa (multi-word, >32 core)
to_hexmask() {
  local cpu="$1" word=$((cpu/32)) bit=$((cpu%32))
  local -a words; for ((i=0;i<=word;i++)); do words[i]=0; done
  words[$word]=$((1<<bit))
  local out=""; for ((i=${#words[@]}-1;i>=0;i--)); do
    out+="${out:+,}$(printf "%x" "${words[i]}")"
  done; echo "$out"
}

# collect IRQ candidate
declare -a irqs
if [[ -n "$IFACE" ]]; then
  # find via iface duluhh
  mapfile -t irqs < <(grep -E "[[:space:]]${IFACE}(:|[[:space:]]|$)" /proc/interrupts \
                      | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1}')
  # kalau kosong, try via driver from sysfs (ex. iwlwifi)
  if [[ ${#irqs[@]} -eq 0 && -e "/sys/class/net/${IFACE}/device/driver" ]]; then
    drv=$(basename "$(readlink -f /sys/class/net/${IFACE}/device/driver)")
    mapfile -t irqs < <(grep -E "[[:space:]]${drv}(:|[[:space:]]|$)" /proc/interrupts \
                        | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1}')
  fi
else
  mapfile -t irqs < <(grep -E "(${NIC_PAT})" /proc/interrupts \
                      | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1}')
fi
mapfile -t irqs < <(printf "%s\n" "${irqs[@]}" | sort -n | uniq)

[[ ${#irqs[@]} -eq 0 ]] && { echo "no NIC IRQ found (IFACE='${IFACE:-all}')"; exit 0; }

echo "[*] IRQs: ${irqs[*]}"

# Apply round-robin
for irq in "${irqs[@]}"; do
  line=$(grep -E "^[[:space:]]*$irq:" /proc/interrupts || true)
  [[ -z "$line" ]] && continue

  ints=$(echo "$line" | awk '{sum=0; for(i=2;i<=NF-1;i++) if($i~/^[0-9]+$/) sum+=$i; print sum+0}')
  [[ "$ints" -eq 0 ]] && continue

  # set core
  core=$(( core_idx % total_cores ))
  (( core==0 && START_CORE>0 )) && core=1

  aff_list="/proc/irq/$irq/smp_affinity_list"
  aff="/proc/irq/$irq/smp_affinity"

  if [[ -w "$aff_list" ]]; then
    echo "$core" > "$aff_list" && echo "IRQ $irq -> CPU $core  (list OK)"
  elif [[ -w "$aff" ]]; then
    hex=$(to_hexmask "$core")
    echo "$hex" > "$aff" && echo "IRQ $irq -> CPU $core  (mask 0x$hex)"
  else
    echo "IRQ $irq -> no writable affinity"
  fi

  ((core_idx++))
done

echo "[*] done."
