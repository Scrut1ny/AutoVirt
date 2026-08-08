#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "Failed to change to script directory: $SCRIPT_DIR"; exit 1; }

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }





detect_root() {
  if [[ $EUID -eq 0 ]]; then
    fmtr::fatal "Do not run as root.\n"
    exit 1
  fi
}





detect_distro() {
  EXPERIMENTAL=${EXPERIMENTAL:-0}
  local id=""

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    id=${ID,,}
  fi

  if [[ $id =~ ^(arch|manjaro|endeavouros|arcolinux|garuda|artix)$ ]] ||
     { command -v pacman >/dev/null 2>&1 && [[ -d /etc/pacman.d ]]; }; then
    DISTRO="Arch"

  # Experimental mode
  elif (( EXPERIMENTAL )); then
    case "$id" in
      opensuse-*|sles)
        DISTRO="openSUSE"
        ;;
      debian|ubuntu|linuxmint|kali|pureos|pop|elementary|zorin|mx|parrot|deepin|peppermint|trisquel|bodhi|linuxlite|neon)
        DISTRO="Debian"
        ;;
      fedora|centos|rhel|rocky|alma|oracle)
        DISTRO="Fedora"
        ;;
      *)
        if command -v apt >/dev/null 2>&1; then
          DISTRO="Debian"
        elif command -v zypper >/dev/null 2>&1; then
          DISTRO="openSUSE"
        elif command -v dnf >/dev/null 2>&1; then
          DISTRO="Fedora"
        else
          fmtr::fatal "${id:-Unknown} distro isn't supported."
        fi
        ;;
    esac

  else
    fmtr::fatal "${id:-Unknown} distro isn't supported (Arch only)."
  fi

  export DISTRO EXPERIMENTAL
  readonly DISTRO EXPERIMENTAL
}





detect_cpu() {
  local line

  while IFS= read -r line; do
    case "$line" in
      *GenuineIntel*)
        CPU_VENDOR_ID="GenuineIntel"
        CPU_VIRTUALIZATION="vmx"
        CPU_MANUFACTURER="Intel"
        break
        ;;
      *AuthenticAMD*)
        CPU_VENDOR_ID="AuthenticAMD"
        CPU_VIRTUALIZATION="svm"
        CPU_MANUFACTURER="AMD"
        break
        ;;
    esac
  done < /proc/cpuinfo

  [[ -n $CPU_VENDOR_ID ]] || fmtr::fatal "Unsupported CPU vendor"

  export CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
  readonly CPU_VENDOR_ID CPU_VIRTUALIZATION CPU_MANUFACTURER
}





main_menu() {
  local menu=(
    "Virtualization Setup|virtualization.sh"
    "QEMU (Patched) Setup|qemu.sh"
    "EDK2 (Patched) Setup|edk2.sh"
    "GPU Passthrough Setup|vfio.sh"
    "Kernel (Patched) Setup|kernel.sh"
    "Looking Glass Setup|lg.sh"
    "Deploy Auto/Unattended XML|deploy.sh"
  )

  # Handle Ctrl+C
  trap '
    clear & echo
    if prmt::yes_or_no "$(fmtr::ask "Do you want to clear the logs directory?")"; then
      rm -f -- "${LOG_PATH}"/*.log
    fi
    exit 0
  ' INT

  while :; do
    clear
    fmtr::box_text " >> AutoVirt << "; echo ""

    for i in "${!menu[@]}"; do
      printf '  %b[%d]%b %s\n' \
        "$TEXT_BRIGHT_YELLOW" "$((i+1))" "$RESET" "${menu[i]%%|*}"
    done
    echo

    local choice
    choice="$(prmt::quick_prompt '  Enter your choice [1-7]: ')" || continue
    clear

    if (( choice >= 1 && choice <= ${#menu[@]} )); then
      local idx=$((choice - 1))
      local label="${menu[idx]%%|*}"
      local script="${menu[idx]#*|}"

      fmtr::box_text "$label"
      if [[ -n "$script" ]]; then
        "$SCRIPT_DIR/modules/$script"
      else
        fmtr::warn "This module isn't ready yet."
      fi
    else
      fmtr::error "Invalid option, please try again."
    fi

    prmt::quick_prompt "$(fmtr::info 'Press any key to continue...')"
  done
}





main() {
  detect_root
  detect_distro
  detect_cpu
  main_menu
}

main
