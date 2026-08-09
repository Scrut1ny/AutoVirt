#!/usr/bin/env bash

source "$(dirname "$0")/../utils.sh" || { echo "Failed to load utilities module!"; exit 1; }

readonly SRC_DIR="$(pwd)/src"
readonly LG_URL="https://looking-glass.io/artifact/stable/source"
readonly LG_VERSION="B7"
readonly LG_ARCHIVE="looking-glass-$LG_VERSION.tar.gz"

# https://looking-glass.io/docs/B7/build/#host
# https://looking-glass.io/wiki/Installation_on_other_distributions

REQUIRED_PKGS_Arch=(
  cmake gcc libgl libegl fontconfig spice-protocol make nettle pkgconf binutils libxi libxinerama
  libxss libxcursor libxpresent libxkbcommon wayland-protocols ttf-dejavu libsamplerate curl
)

REQUIRED_PKGS_Debian=(
  # https://looking-glass.io/docs/B7/build/#fetching-with-apt
  
  binutils-dev cmake fonts-dejavu-core libfontconfig-dev curl
  gcc g++ pkg-config libegl-dev libgl-dev libgles-dev libspice-protocol-dev
  nettle-dev libx11-dev libxcursor-dev libxi-dev libxinerama-dev
  libxpresent-dev libxss-dev libxkbcommon-dev libwayland-dev wayland-protocols
  libpipewire-0.3-dev libsamplerate0-dev

  # Add "libpulse-devel" and remove "pipewire-devel" if you use PulseAudio!
  # Not recommended though because LG doesn't support PulseAudio.
)

REQUIRED_PKGS_openSUSE=(
  binutils-devel clang cmake dejavu-fonts fontconfig-devel gcc gcc-c++ glibc-locale 
  libdecor-devel libglvnd-devel libnettle-devel libsamplerate-devel libSDL2-2_0-0
  libSDL2_ttf-2_0-0 libvulkan1 libwayland-egl1 libxkbcommon-devel libXpresent-devel
  libXrandr-devel libXss-devel libXss-devel make Mesa-libGLESv3-devel pipewire-devel
  pkgconf-pkg-config pkgconf spice-protocol-devel vulkan-devel wayland-devel
  zlib-devel-static libXi-devel libXinerama-devel libXcursor-devel dkms Mesa-libGL-devel
  Mesa-libGLESv2-devel libzstd-devel-static libconfig++-devel SDL2-devel curl

  # Add "libpulse-devel" and remove "pipewire-devel" if you use PulseAudio!
  # Not recommended though because LG doesn't support PulseAudio.
)

REQUIRED_PKGS_Fedora=(
  cmake gcc gcc-c++ libglvnd-devel fontconfig-devel spice-protocol make nettle-devel
  pkgconf-pkg-config binutils-devel libXi-devel libXinerama-devel libXcursor-devel
  libXpresent-devel libxkbcommon-x11-devel wayland-devel wayland-protocols-devel
  libXScrnSaver-devel libXrandr-devel dejavu-sans-mono-fonts libdecor-devel
  pipewire-devel libsamplerate-devel dkms kernel-devel kernel-headers curl

  # Add "pulseaudio-libs-devel" and remove "pipewire-devel" if you use PulseAudio!
  # Not recommended though because LG doesn't support PulseAudio.
)

install_looking_glass() {

  # openSUSE specific thing
  if [[ "$DISTRO" == "openSUSE" && ! -e /usr/lib64/libbfd.so ]]; then
    fmtr::log "Configuring packages to ensure LG build completion"
    {
      LIBBFD_OLD=$(find /usr -name "libbfd*.so*" 2>/dev/null | head -n 1)
      if [[ -n "$LIBBFD_OLD" ]]; then
        ln -sv "$LIBBFD_OLD" /usr/lib64/libbfd.so
      else
        fmtr::log "libbfd library not found in /usr"
      fi
    } &>> "$LOG_FILE"
  fi
  
  mkdir -p "$SRC_DIR" && cd "$SRC_DIR"

  fmtr::info "Downloading 'looking-glass-$LG_VERSION.tar.gz' archive..."
  curl -sSo "$LG_ARCHIVE" "$LG_URL" && tar -zxf "$LG_ARCHIVE" && rm -f "$LG_ARCHIVE"

  fmtr::info "Building, compiling, and installing LG..."
  cd looking-glass-$LG_VERSION && mkdir client/build && cd client/build

  if [[ "$CPU_VENDOR_ID" == "GenuineIntel" ]]; then
      NEW_VENDOR_ID="0x8086"
      NEW_DEVICE_ID="0x8086"
  elif [[ "$CPU_VENDOR_ID" == "AuthenticAMD" ]]; then
      NEW_VENDOR_ID="0x1022"
      NEW_DEVICE_ID="0x1022"
  else
      fmtr::error "Unknown CPU Vendor ID."; exit 1
  fi

  sed -i "s/0x1af4/$NEW_VENDOR_ID/" "../../module/kvmfr.c"
  sed -i "s/0x1110/$NEW_DEVICE_ID/" "../../module/kvmfr.c"

  {
    cmake ../ && $ROOT_ESC make install -j"$(nproc)"
  } &>> "$LOG_FILE"

  fmtr::info "Cleaning up..."
  cd "$SRC_DIR" && rm -rf looking-glass-$LG_VERSION/

}

configure_ivshmem_shmem() {

    local conf_file="/etc/tmpfiles.d/10-looking-glass.conf"
    local username=$(whoami)

    if [ ! -f "$conf_file" ]; then
      fmtr::info "Creating '10-looking-glass.conf'..."
      echo "f /dev/shm/looking-glass 0660 ${username} kvm -" | $ROOT_ESC tee "$conf_file" &>> "$LOG_FILE"
    else
      fmtr::log "'10-looking-glass.conf' already exists; skipping creation."
    fi

    if [ ! -e /dev/shm/looking-glass ]; then
      fmtr::info "Creating '/dev/shm/looking-glass' and setting permissions..."
      $ROOT_ESC touch /dev/shm/looking-glass
      $ROOT_ESC chown "${username}:kvm" /dev/shm/looking-glass
      $ROOT_ESC chmod 660 /dev/shm/looking-glass
    else
      fmtr::log "'/dev/shm/looking-glass' already exists; skipping creation."
    fi

    local entry_to_add="$(cat <<- 'EOF'
# Alias lg for Looking Glass shared memory setup
alias lg='if [ ! -e /dev/shm/looking-glass ]; then \
  touch /dev/shm/looking-glass; \
  sudo chown $USER:kvm /dev/shm/looking-glass; \
  chmod 660 /dev/shm/looking-glass; \
  /usr/local/bin/looking-glass-client -S -K -1; \
else \
  /usr/local/bin/looking-glass-client -S -K -1; \
fi'
EOF
    )"

    if ! grep -q "alias lg=" ~/.bashrc; then
      fmtr::info "Adding LG alias to '~/.bashrc'..."
      echo "$entry_to_add" >> ~/.bashrc
    else
      fmtr::log "The LG alias already exists in '~/.bashrc'; skipping creation."
    fi

    source "${HOME}/.bashrc"
    fmtr::warn "TIP: Just enter 'lg' in a fresh terminal to launch LG."

}

configure_ivshmem_kvmfr() {

  # The kernel module implements a basic interface to the IVSHMEM device for Looking Glass allowing DMA GPU transfers.

  local MEMORY_SIZE_MB="32"

  # Temporary
  $ROOT_ESC modprobe kvmfr static_size_mb=$MEMORY_SIZE_MB

  # Permanent
  echo "options kvmfr static_size_mb=$MEMORY_SIZE_MB" | $ROOT_ESC tee /etc/modprobe.d/kvmfr.conf

  # Automatic (w/systemd)
  echo -e "# KVMFR Looking Glass module\nkvmfr" | $ROOT_ESC tee /etc/modules-load.d/kvmfr.conf

  # Permissions
  $ROOT_ESC chown $(whoami):kvm /dev/kvmfr0

}

main() {

  install_req_pkgs "LG"
  install_looking_glass
  configure_ivshmem_shmem
  configure_ivshmem_kvmfr
  
}

main
