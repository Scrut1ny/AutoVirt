#!/usr/bin/env bash

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }





REQUIRED_PKGS_Arch=(
  dnsmasq libvirt virt-manager swtpm
  # qemu-base edk2-ovmf
)

# EXPERIMENTAL
REQUIRED_PKGS_Debian=(
  qemu-system-x86 ovmf virt-manager libvirt-clients swtpm
  libvirt-daemon-system libvirt-daemon-config-network
)

# EXPERIMENTAL
REQUIRED_PKGS_openSUSE=(
  libvirt libvirt-client libvirt-daemon virt-manager
  qemu qemu-kvm ovmf qemu-tools swtpm
)

# EXPERIMENTAL
REQUIRED_PKGS_Fedora=(
  @virtualization swtpm
)





configure_system_installation() {
  local target_user="${SUDO_USER:-$USER}"
  local user_groups=" $(id -nG "$target_user") "

  # $USER Groups: input, kvm, and libvirt
  for grp in input kvm libvirt; do
      if [[ "$user_groups" == *" $grp "* ]]; then
          fmtr::info "User '$target_user' already has group '$grp' *skipping*"
      else
          $ROOT_ESC usermod -aG "$grp" "$target_user"
          fmtr::info "User '$target_user' now has group '$grp'"
      fi
  done

  # Enable (autostart) & start libvirt service
  if ! systemctl is-active --quiet libvirtd; then
      $ROOT_ESC systemctl enable --now libvirtd
  fi

  # Generate hybrid MAC address
  GATEWAY=$(ip route show default | awk '/default/ {print $3}') || { fmtr::error "No gateway detected"; return; }
  ping -c 1 -W 1 "$GATEWAY" &>/dev/null
  ROUTER_MAC=$(awk -v gw="$GATEWAY" '$1==gw{print $4}' /proc/net/arp) || { fmtr::error "No router MAC found"; return; }
  OUI="${ROUTER_MAC%:*:*:*}"
  TAIL=$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
  HYBRID_MAC="$OUI:$TAIL"

  # Pick 10.0.0.0/24 unless it already exists on the host, then use the next free 10.0.x.0/24.
  AUTOVIRT_SUBNET="10.0.0"
  for i in {0..254}; do
      candidate="10.0.$i"
      if ! ip route show | grep -qE "(^|[[:space:]])${candidate//./\\.}\.0/24([[:space:]]|$)"; then
          AUTOVIRT_SUBNET="$candidate"
          break
      fi
  done

  # Define libvirt network if missing
  if ! $ROOT_ESC virsh net-info AutoVirt-Router &>> "$LOG_FILE"; then
      $ROOT_ESC virsh net-define /dev/stdin &>> "$LOG_FILE" <<EOF
  <network>
    <name>AutoVirt-Router</name>
    <forward mode="nat"/>
    <mac address="$HYBRID_MAC"/>
    <ip address="${AUTOVIRT_SUBNET}.1" netmask="255.255.255.0">
      <dhcp>
        <range start="${AUTOVIRT_SUBNET}.2" end="${AUTOVIRT_SUBNET}.254"/>
      </dhcp>
    </ip>
  </network>
EOF
      $ROOT_ESC virsh net-autostart AutoVirt-Router &>> "$LOG_FILE"
      $ROOT_ESC virsh net-start AutoVirt-Router &>> "$LOG_FILE"
      fmtr::info "AutoVirt-Router network created and started."
  else
      fmtr::info "'AutoVirt-Router' network already exists. *skipping*"
  fi
}





main() {
  install_req_pkgs "virt"
  configure_system_installation
  fmtr::warn "Logout or reboot for all group and service changes to take effect."
}

main
