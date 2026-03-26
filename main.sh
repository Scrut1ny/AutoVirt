#!/usr/bin/env bash

# Resolve the script's own directory so relative paths work from anywhere
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR" || { echo "Failed to cd to script directory: $SCRIPT_DIR"; exit 1; }

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }

check_non_root() {
  if [[ $EUID -eq 0 ]]; then
    fmtr::fatal "Do not run as root.\n"
    exit 1
  fi
}

detect_distro() {
  local id

  # Try reading /etc/os-release first
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    id=${ID,,}
  fi

  # Map known distro IDs to canonical names
  case "$id" in
    arch|manjaro|endeavouros|arcolinux|garuda|artix) DISTRO="Arch" ;;
    opensuse-*|sles) DISTRO="openSUSE" ;;
    debian|ubuntu|linuxmint|kali|pureos|pop|elementary|zorin|mx|parrot|deepin|peppermint|trisquel|bodhi|linuxlite|neon) DISTRO="Debian" ;;
    fedora|centos|rhel|rocky|alma|oracle) DISTRO="Fedora" ;;
    *)
      # Fallback: detect by package manager
      if command -v pacman >/dev/null 2>&1; then
        DISTRO="Arch"
      elif command -v apt >/dev/null 2>&1; then
        DISTRO="Debian"
      elif command -v zypper >/dev/null 2>&1; then
        DISTRO="openSUSE"
      elif command -v dnf >/dev/null 2>&1; then
        DISTRO="Fedora"
      else
        fmtr::fatal "${id:-Unknown} distro isn't supported yet."
      fi
      ;;
  esac

  export DISTRO
  readonly DISTRO
}

cpu_detect() {
  local vendor
  vendor=$(awk -F': +' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)

  [[ -n $vendor ]] || fmtr::fatal "Unable to determine CPU vendor from /proc/cpuinfo"

  case "$vendor" in
    *AuthenticAMD*)
      CPU_VENDOR_ID="AuthenticAMD"
      CPU_VIRTUALIZATION="svm"
      CPU_MANUFACTURER="AMD"
      ;;
    *GenuineIntel*)
      CPU_VENDOR_ID="GenuineIntel"
      CPU_VIRTUALIZATION="vmx"
      CPU_MANUFACTURER="Intel"
      ;;
    *)
      fmtr::fatal "Unsupported CPU vendor: $vendor"
      ;;
  esac

  export CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
  readonly CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
}

main_menu() {
  local options=(
    "Exit"
    "Virtualization Setup"
    "QEMU (Patched) Setup"
    "EDK2 (Patched) Setup"
    "GPU Passthrough Setup"
    "Kernel (Patched) Setup"
    "Looking Glass Setup"
    "Deploy Auto/Unattended XML"
  )
  readonly options

  while :; do
    clear
    fmtr::box_text " >> AutoVirt << "; echo ""

    for ((i=1; i<${#options[@]}; i++)); do
      printf '  %b[%d]%b %s\n' "$TEXT_BRIGHT_YELLOW" "$i" "$RESET" "${options[i]}"
    done
    printf '\n  %b[%d]%b %s\n\n' "$TEXT_BRIGHT_RED" 0 "$RESET" "${options[0]}"

    local choice
    choice="$(prmt::quick_prompt '  Enter your choice [0-7]: ')" || continue
    clear

    case $choice in
      1) fmtr::box_text "${options[1]}"; ./modules/virtualization.sh ;;
      2) fmtr::box_text "${options[2]}"; ./modules/qemu.sh ;;
      3) fmtr::box_text "${options[3]}"; ./modules/edk2.sh ;;
      4) fmtr::box_text "${options[4]}"; ./modules/vfio.sh ;;
      5) fmtr::box_text "${options[5]}"; fmtr::warn "This module isn't ready yet." ;; #./modules/kernel.sh ;;
      6) fmtr::box_text "${options[6]}"; fmtr::warn "This module isn't ready yet." ;; #./modules/lg.sh ;;
      7) fmtr::box_text "${options[7]}"; ./modules/deploy.sh ;;
      0)
        prmt::yes_or_no "$(fmtr::ask 'Do you want to clear the logs directory?')" &&
          rm -f -- "${LOG_PATH}"/*.log
        exit 0
        ;;
      *) fmtr::error "Invalid option, please try again." ;;
    esac

    prmt::quick_prompt "$(fmtr::info 'Press any key to continue...')"
  done
}

main() {
  check_non_root
  detect_distro
  cpu_detect
  main_menu
}

main
