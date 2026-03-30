#!/usr/bin/env bash

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }

readonly SRC_DIR="$(pwd)/src"
readonly OUT_DIR="/opt/AutoVirt"

readonly QEMU_TAG="v10.2.0"
readonly QEMU_URL="https://gitlab.com/qemu-project/qemu.git"

readonly QEMU_PATCH="$(pwd)/patches/QEMU/${CPU_MANUFACTURER}-${QEMU_TAG}.patch"

REQUIRED_PKGS_Arch=(
  # Basic Build Dependencie(s)
  acpica base-devel dmidecode glib2 ninja python-packaging
  python-sphinx python-sphinx_rtd_theme gnupg libevdev

  # Spice Dependencie(s)
  spice gtk3

  # USB passthrough Dependencie(s)
  libusb

  # USB redirection Dependencie(s)
  usbredir
)

REQUIRED_PKGS_Debian=(
  # Basic Build Dependencie(s)
  acpica-tools build-essential libfdt-dev libglib2.0-dev
  libpixman-1-dev ninja-build python3-venv zlib1g-dev gnupg
  python3-sphinx python3-sphinx-rtd-theme

  # Spice Dependencie(s)
  libspice-server-dev

  # USB passthrough Dependencie(s)
  libusb-1.0-0-dev

  # USB redirection Dependencie(s)
  libusbredirhost-dev libusbredirparser-dev
)

REQUIRED_PKGS_openSUSE=(
  # Basic Build Dependencie(s)
  acpica bzip2 gcc-c++ gpg2 glib2-devel make qemu
  libpixman-1-0-devel python3-Sphinx ninja

  # Spice Dependencie(s)
  spice-server

  # USB passthrough Dependencie(s)
  libusb-1_0-devel

  # USB redirection Dependencie(s)
  libusbredir-devel
)

REQUIRED_PKGS_Fedora=(
  # Basic Build Dependencie(s)
  acpica-tools bzip2 glib2-devel libfdt-devel ninja-build
  pixman-devel python3 zlib-ng-devel gnupg2

  # Spice Dependencie(s)
  spice-server-devel

  # USB passthrough Dependencie(s)
  libusb1-devel

  # USB redirection Dependencie(s)
  usbredir-devel
)

################################################################################
# Acquire QEMU source
################################################################################
acquire_qemu_source() {
  $ROOT_ESC mkdir -p "$OUT_DIR"/{emulator,firmware}
  mkdir -p "$SRC_DIR" && cd "$SRC_DIR" || { fmtr::fatal "Failed to enter source dir: $SRC_DIR"; exit 1; }

  clone_repo() {
    fmtr::info "Cloning '$QEMU_TAG' from '$QEMU_URL'..."
    git clone --depth=1 --branch "$QEMU_TAG" "$QEMU_URL" "$QEMU_TAG" &>>"$LOG_FILE" \
      || { fmtr::fatal "Failed to clone repository!"; exit 1; }
    cd "$QEMU_TAG" || { fmtr::fatal "Missing '$QEMU_TAG' directory!"; exit 1; }
    patch_qemu
  }

  if [ -d "$QEMU_TAG" ]; then
    fmtr::warn "Repository directory '$QEMU_TAG' found."
    if prmt::yes_or_no "$(fmtr::ask "Purge '$QEMU_TAG' directory?")"; then
      rm -rf "$QEMU_TAG" || { fmtr::fatal "Failed to purge '$QEMU_TAG' directory!"; exit 1; }
      fmtr::info "Directory purged successfully."
      if prmt::yes_or_no "$(fmtr::ask "Clone '$QEMU_URL' repository again?")"; then
        clone_repo
      else
        fmtr::info "Skipping..."
      fi
    else
      fmtr::info "Skipping..."
      cd "$QEMU_TAG" || { fmtr::fatal "Missing '$QEMU_TAG' directory!"; exit 1; }
    fi
  else
    clone_repo
  fi
}

patch_qemu() {
  [ -f "$QEMU_PATCH" ] || { fmtr::error "Missing '$QEMU_PATCH' patch file!"; return 1; }
  git apply < "$QEMU_PATCH" &>>"$LOG_FILE" || { fmtr::error "Failed to apply '$QEMU_PATCH'!"; return 1; }
  fmtr::log "Applied '${CPU_MANUFACTURER}-${QEMU_TAG}.patch' successfully."

  fmtr::info "Applying dynamic modifications..."
  #spoof_serials
  spoof_models
  spoof_acpi
  spoof_smbios
}












spoof_serials() {
  local patterns=(STRING_SERIALNUMBER STR_SERIALNUMBER STR_SERIAL_MOUSE \
                    STR_SERIAL_TABLET STR_SERIAL_KEYBOARD STR_SERIAL_COMPAT)

  for file in ./hw/usb/*.c; do
    for pat in "${patterns[@]}"; do
      grep -n "\[\s*${pat}\s*\]\s*=\s*\"[^\"]*\"" "$file" | cut -d: -f1 | while read -r lineno; do
        serial=$(tr -dc 'A-Z0-9' </dev/urandom | head -c10)
        sed -r -i "${lineno}s/(\[\s*${pat}\s*\]\s*=\s*\")[^\"]*(\")/\1${serial}\2/" "$file"
      done
    done
  done
}











spoof_models() {
    local ide="hw/ide/core.c"
    local nvme="hw/nvme/ctrl.c"

    local ide_cd_models=(
      "HL-DT-ST BD-RE WH16NS60" "HL-DT-ST DVDRAM GH24NSC0"
      "HL-DT-ST BD-RE BH16NS40" "HL-DT-ST DVD+-RW GT80N"
      "HL-DT-ST DVD-RAM GH22NS30" "HL-DT-ST DVD+RW GCA-4040N"
      "Pioneer BDR-XD07B" "Pioneer DVR-221LBK" "Pioneer BDR-209DBK"
      "Pioneer DVR-S21WBK" "Pioneer BDR-XD05B" "ASUS BW-16D1HT"
      "ASUS DRW-24B1ST" "ASUS SDRW-08D2S-U" "ASUS BC-12D2HT"
      "ASUS SBW-06D2X-U" "Samsung SH-224FB" "Samsung SE-506BB"
      "Samsung SH-B123L" "Samsung SE-208GB" "Samsung SN-208DB"
      "Sony NEC Optiarc AD-5280S" "Sony DRU-870S" "Sony BWU-500S"
      "Sony NEC Optiarc AD-7261S" "Sony AD-7200S" "Lite-On iHAS124-14"
      "Lite-On iHBS112-04" "Lite-On eTAU108" "Lite-On iHAS324-17"
      "Lite-On eBAU108" "HP DVD1260i" "HP DVD640"
      "HP BD-RE BH30L" "HP DVD Writer 300n" "HP DVD Writer 1265i"
    )

    local ide_cfata_models=(
      "SanDisk Ultra microSDXC UHS-I" "SanDisk Extreme microSDXC UHS-I"
      "SanDisk High Endurance microSDXC" "SanDisk Industrial microSD"
      "SanDisk Mobile Ultra microSDHC" "Samsung EVO Select microSDXC"
      "Samsung PRO Endurance microSDHC" "Samsung PRO Plus microSDXC"
      "Samsung EVO Plus microSDXC" "Samsung PRO Ultimate microSDHC"
      "Kingston Canvas React Plus microSD" "Kingston Canvas Go! Plus microSD"
      "Kingston Canvas Select Plus microSD" "Kingston Industrial microSD"
      "Kingston Endurance microSD" "Lexar Professional 1066x microSDXC"
      "Lexar High-Performance 633x microSDHC" "Lexar PLAY microSDXC"
      "Lexar Endurance microSD" "Lexar Professional 1000x microSDHC"
      "PNY Elite-X microSD" "PNY PRO Elite microSD"
      "PNY High Performance microSD" "PNY Turbo Performance microSD"
      "PNY Premier-X microSD" "Transcend High Endurance microSDXC"
      "Transcend Ultimate microSDXC" "Transcend Industrial Temp microSD"
      "Transcend Premium microSDHC" "Transcend Superior microSD"
      "ADATA Premier Pro microSDXC" "ADATA XPG microSDXC"
      "ADATA High Endurance microSDXC" "ADATA Premier microSDHC"
      "ADATA Industrial microSD" "Toshiba Exceria Pro microSDXC"
      "Toshiba Exceria microSDHC" "Toshiba M203 microSD"
      "Toshiba N203 microSD" "Toshiba High Endurance microSD"
    )

    local default_models=(
      "Samsung SSD 970 EVO 1TB" "Samsung SSD 860 QVO 1TB"
      "Samsung SSD 850 PRO 1TB" "Samsung SSD T7 Touch 1TB"
      "Samsung SSD 840 EVO 1TB" "WD Blue SN570 NVMe SSD 1TB"
      "WD Black SN850 NVMe SSD 1TB" "WD Green 1TB SSD"
      "WD Blue 3D NAND 1TB SSD" "Crucial P3 1TB PCIe 3.0 3D NAND NVMe SSD"
      "Seagate BarraCuda SSD 1TB" "Seagate FireCuda 520 SSD 1TB"
      "Seagate IronWolf 110 SSD 1TB" "SanDisk Ultra 3D NAND SSD 1TB"
      "Seagate Fast SSD 1TB" "Crucial MX500 1TB 3D NAND SSD"
      "Crucial P5 Plus NVMe SSD 1TB" "Crucial BX500 1TB 3D NAND SSD"
      "Crucial P3 1TB PCIe 3.0 3D NAND NVMe SSD"
      "Kingston A2000 NVMe SSD 1TB" "Kingston KC2500 NVMe SSD 1TB"
      "Kingston A400 SSD 1TB" "Kingston HyperX Savage SSD 1TB"
      "SanDisk SSD PLUS 1TB" "SanDisk Ultra 3D 1TB NAND SSD"
    )

    get_random_element() {
      local array=("$@")
      echo "${array[RANDOM % ${#array[@]}]}"
    }

    local new_ide_cd_model=$(get_random_element "${ide_cd_models[@]}")
    local new_ide_cfata_model=$(get_random_element "${ide_cfata_models[@]}")
    local new_default_model=$(get_random_element "${default_models[@]}")

    sed -i "$ide" -Ee "s/\"HL-DT-ST BD-RE WH16NS60\"/\"${new_ide_cd_model}\"/"
    sed -i "$ide" -Ee "s/\"Hitachi HMS360404D5CF00\"/\"${new_ide_cfata_model}\"/"
    sed -i "$ide" -Ee "s/\"Samsung SSD 980 500GB\"/\"${new_default_model}\"/"
    sed -i "$nvme" -Ee "s/\"NVMe Ctrl\"/\"${new_default_model}\"/"
}








spoof_acpi() {
  # Fixed ACPI Description Table (FADT) - https://uefi.org/sites/default/files/resources/ACPI_Spec_6.6.pdf#subsection.5.2.9
  # Preferred PM Profile System Types   - https://uefi.org/sites/default/files/resources/ACPI_Spec_6.6.pdf#subsubsection.5.2.9.1

  local t=/sys/firmware/acpi/tables/FACP
  local h=include/hw/acpi/aml-build.h
  local c=hw/acpi/aml-build.c

  local OEMID OEM_Table_ID Creator_ID Preferred_PM_Profile Battery_SSDT out

  OEMID="$(LC_ALL=C $ROOT_ESC dd if=$t bs=1 skip=10 count=6 status=none | tr '\0' ' ')"
  OEM_Table_ID="$(LC_ALL=C $ROOT_ESC dd if=$t bs=1 skip=16 count=8 status=none | tr '\0' ' ')"
  Creator_ID="$(LC_ALL=C $ROOT_ESC dd if=$t bs=1 skip=28 count=4 status=none | tr '\0' ' ')"
  Preferred_PM_Profile=$(LC_ALL=C $ROOT_ESC dd if=$t bs=1 skip=45 count=1 status=none | od -An -tu1)

  sed -i \
    -e "s/\(#define ACPI_BUILD_APPNAME6 \)\"[^\"]*\"/\1\"$OEMID\"/" \
    -e "s/\(#define ACPI_BUILD_APPNAME8 \)\"[^\"]*\"/\1\"$OEM_Table_ID\"/" \
    $h

  sed -i 's/"ACPI"/"'"$Creator_ID"'"/g' $c

  if [[ $Preferred_PM_Profile -eq 2 ]]; then
    fmtr::warn "Host FADT: Preferred_PM_Profile equals '2' (Mobile)"

    sed -i 's/1 \/\* Desktop \*\/, 1/2 \/\* Mobile \*\/, 1/' "$c"

    Battery_SSDT=$($ROOT_ESC grep -aliE 'Battery|Capacity|Discharge|Charge' /sys/firmware/acpi/tables/SSDT* 2>/dev/null | head -n 1)

    if [[ -n "$Battery_SSDT" ]]; then
      out="$OUT_DIR/firmware/$(basename "$Battery_SSDT")-battery.aml"

      if $ROOT_ESC cp -- "$Battery_SSDT" "$out" && \
         $ROOT_ESC chmod 0644 -- "$out" && \
         $ROOT_ESC chown -- "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$out" 2>/dev/null; then

         fmtr::info "Copied '$Battery_SSDT' to '$out'"
      else
         fmtr::error "Failed to copy or set permissions for battery SSDT"
      fi
    else
      fmtr::warn "No SSDT containing battery info found; skipping battery SSDT copy."
    fi
  fi
}











spoof_smbios() {
  local chipset_file

  case "$QEMU_TAG" in
    "v8.2.6")
      chipset_file="hw/i386/pc_q35.c"
      ;;
    v9.*|v10.*.*)
      chipset_file="hw/i386/fw_cfg.c"
      ;;
    *)
      fmtr::warn "Unsupported QEMU version: $QEMU_TAG — skipping SMBIOS spoofing."
      return 1
      ;;
  esac

  [[ -f "$chipset_file" ]] || { fmtr::error "Chipset file not found: $chipset_file"; return 1; }

  local manufacturer=$($ROOT_ESC dmidecode --string processor-manufacturer)
  [[ -n "$manufacturer" ]] || { fmtr::error "Failed to get processor manufacturer from dmidecode"; return 1; }

  sed -i "$chipset_file" -e "s/smbios_set_defaults(\"[^\"]*\",/smbios_set_defaults(\"${manufacturer}\",/"

  # TODO: Implement smbios.bin spoofer
}
















compile_qemu() {
  fmtr::info "Configuring QEMU..."

  ./configure --target-list=x86_64-softmmu \
              --prefix="$OUT_DIR/emulator" \
              --enable-libusb \
              --enable-usb-redir \
              --enable-spice \
              --enable-spice-protocol \
              --disable-werror \
              --disable-docs &>> "$LOG_FILE"

  if [[ $? -ne 0 ]]; then
    fmtr::error "Configuration failed; Check $LOG_FILE"
    return 1
  fi

  fmtr::info "Compiling QEMU..."
  make -j"$(nproc)" &>> "$LOG_FILE"
  if [[ $? -ne 0 ]]; then
    fmtr::error "Compilation failed; Check $LOG_FILE"
    return 1
  fi

  $ROOT_ESC make install &>> "$LOG_FILE"
  if [[ $? -ne 0 ]]; then
    fmtr::error "Install failed; Check $LOG_FILE"
    return 1
  fi
  fmtr::log "Installed QEMU at '$OUT_DIR/emulator'"
}











cleanup() {
  fmtr::info "Cleaning up..."
  rm -rf "$SRC_DIR/$QEMU_TAG"
  rmdir --ignore-fail-on-non-empty "$SRC_DIR" 2>/dev/null || true
}











main() {
  install_req_pkgs "QEMU"
  acquire_qemu_source
  prmt::yes_or_no "$(fmtr::ask "Build & install QEMU?")" && compile_qemu
  ! prmt::yes_or_no "$(fmtr::ask "Keep repository directory?")" && cleanup
}

main
