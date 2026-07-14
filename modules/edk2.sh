#!/usr/bin/env bash

source "$(dirname "$0")/../utils.sh" || { echo "Failed to load utilities module!"; exit 1; }





readonly SRC_DIR="$(pwd)/src"
readonly OUT_DIR="/opt/AutoVirt"

readonly EDK2_URI="https://github.com/tianocore/edk2.git"
readonly EDK2_TAG="edk2-stable202605"

readonly OVMF_PATCH="$(pwd)/patches/EDK2/${CPU_MANUFACTURER}-${EDK2_TAG}.patch"





REQUIRED_PKGS_Arch=(
  # build dependencies
  base-devel nasm acpica

  # script dependencies
  git virt-firmware
)

# EXPERIMENTAL
REQUIRED_PKGS_Debian=(
  # build dependencies
  build-essential nasm acpica-tools uuid-dev

  # script dependencies
  git python-is-python3 python3-virt-firmware
)

# EXPERIMENTAL
REQUIRED_PKGS_openSUSE=(
  # build dependencies
  gcc gcc-c++ make nasm acpica libuuid-devel

  # script dependencies
  git python3 virt-firmware
)

# EXPERIMENTAL
REQUIRED_PKGS_Fedora=(
  # build dependencies
  gcc gcc-c++ make nasm acpica-tools libuuid-devel

  # script dependencies
  git python3 python3-virt-firmware
)





################################################################################
# Acquire EDK2 source
################################################################################
acquire_edk2_source() {
  $ROOT_ESC mkdir -p "$OUT_DIR/firmware"
  mkdir -p "$SRC_DIR" && cd "$SRC_DIR" || { fmtr::fatal "Failed to enter source dir: $SRC_DIR"; exit 1; }

  clone_repo() {
    fmtr::info "Cloning '$EDK2_TAG' from '$EDK2_URI'..."
    git clone --depth=1 --branch="$EDK2_TAG" "$EDK2_URI" "$EDK2_TAG" &>>"$LOG_FILE" \
    || { fmtr::fatal "Clone failed!"; exit 1; }

    cd "$EDK2_TAG" || { fmtr::fatal "Missing '$EDK2_TAG' directory!"; exit 1; }

    fmtr::info "Initializing submodules..."
    git submodule update --init --depth=1 --jobs="$(nproc)" &>>"$LOG_FILE" \
      || { fmtr::fatal "Submodule update failed!"; exit 1; }

    patch_ovmf
  }

  if [ -d "$EDK2_TAG" ]; then
    fmtr::warn "Repository directory '$EDK2_TAG' found."
    if prmt::yes_or_no "$(fmtr::ask "Purge '$EDK2_TAG' directory?")"; then
      rm -rf "$EDK2_TAG" || { fmtr::fatal "Failed to purge '$EDK2_TAG' directory!"; exit 1; }
      fmtr::info "Directory purged successfully."
      if prmt::yes_or_no "$(fmtr::ask "Clone '$EDK2_URI' repository again?")"; then
        clone_repo
      else
        fmtr::info "Skipping..."
      fi
    else
      fmtr::info "Skipping..."
      cd "$EDK2_TAG" || { fmtr::fatal "Missing '$EDK2_TAG' directory!"; exit 1; }
    fi
  else
    clone_repo
  fi
}





################################################################################
# Patch OVMF
################################################################################
patch_ovmf() {
  local BIOS_VENDOR BIOS_VERSION BIOS_DATE
  local logo_choice custom_bmp width height bit_depth compression





  # --- Phase 1: Source Patching ---
  [ -f "$OVMF_PATCH" ] || { fmtr::error "Patch file missing"; return 1; }

  git apply < "$OVMF_PATCH" &>>"$LOG_FILE" || {
    fmtr::error "Patch application failed"; return 1;
  }
  fmtr::log "Source code patched."





  # --- Phase 2: Firmware Spoofing ---
  fmtr::info "Modifying firmware metadata..."

  uhex() {
    local bytes="$1" v="$2" width=$((bytes * 2))
    case "$v" in
      0x*|0X*) printf "0x%0${width}X" "$((v))" ;;
      *.*)     IFS='.' read -r a b _ <<< "$v"; b="${b:-0}"
              if (( bytes == 4 )); then printf "0x%0${width}X" "$(( (a << 16) | b ))"
              else                      printf "0x%0${width}X" "$(( (a << 48) | (b << 32) ))"
              fi ;;
      [0-9]*)  printf "0x%0${width}X" "$v" ;;
      *)       printf "%-${bytes}s" "$v" | LC_ALL=C od -An -t x1 -v \
                | awk '{for(i=NF;i>=1;i--) printf $i} END{print ""}' \
                | sed 's/^/0x/' ;;
    esac
  }

  BIOS_VENDOR="$(</sys/class/dmi/id/bios_vendor)"
  BIOS_VERSION="$(</sys/class/dmi/id/bios_version)"
  BIOS_DATE="$(</sys/class/dmi/id/bios_date)"
  BIOS_REVISION="$(uhex 4 "$($ROOT_ESC dmidecode --string bios-revision)")"

  t=/sys/firmware/acpi/tables/FACP

  OEM_Revision="$(uhex 4 "$(LC_ALL=C $ROOT_ESC od -An -t u4 -j 24 -N4 "$t" | tr -d ' ')")"
  Creator_Revision="$(uhex 4 "$(LC_ALL=C $ROOT_ESC od -An -t u4 -j 32 -N4 "$t" | tr -d ' ')")"

  OEM_Table_ID="$(uhex 8 "$(LC_ALL=C $ROOT_ESC dd if="$t" bs=1 skip=16 count=8 status=none | tr '\0' ' ')")"
  Creator_ID="$(uhex 4 "$(LC_ALL=C $ROOT_ESC dd if="$t" bs=1 skip=28 count=4 status=none | tr '\0' ' ')")"
  OEMID="$(LC_ALL=C $ROOT_ESC dd if="$t" bs=1 skip=10 count=6 status=none | tr '\0' ' ')"

  sed -i \
    -e 's@VendStr = L"unknown";@VendStr = L"'"$BIOS_VENDOR"'";@' \
    -e 's@VersStr = L"unknown";@VersStr = L"'"$BIOS_VERSION"'";@' \
    -e 's@DateStr = L"02/02/2022";@DateStr = L"'"$BIOS_DATE"'";@' \
    OvmfPkg/SmbiosPlatformDxe/SmbiosPlatformDxe.c

  sed -E -i \
    -e 's@(PcdFirmwareVendor)\|L"EDK II"\|@\1|L"'"$BIOS_VENDOR"'"|@' \
    -e 's@(PcdFirmwareRevision)\|0x00010000\|@\1|'"$BIOS_REVISION"'|@' \
    -e 's@(PcdFirmwareVersionString)\|L""\|@\1|L"'"$BIOS_VERSION"'"|@' \
    -e 's@(PcdFirmwareReleaseDateString)\|L""\|@\1|L"'"$BIOS_DATE"'"|@' \
    -e 's@(PcdAcpiDefaultOemId)\|"INTEL "\|@\1|"'$OEMID'"|@' \
    -e 's@(PcdAcpiDefaultOemTableId)\|0x20202020324B4445\|@\1|'"$OEM_Table_ID"'|@' \
    -e 's@(PcdAcpiDefaultOemRevision)\|0x00000002\|@\1|'"$OEM_Revision"'|@' \
    -e 's@(PcdAcpiDefaultCreatorId)\|0x20202020\|@\1|'"$Creator_ID"'|@' \
    -e 's@(PcdAcpiDefaultCreatorRevision)\|0x01000013\|@\1|'"$Creator_Revision"'|@' \
    MdeModulePkg/MdeModulePkg.dec





  # --- Phase 3: Boot Logo Replacement ---
  fmtr::info "Select boot logo source:"
  printf '\n  %b[%d]%b %s\n' "$TEXT_BRIGHT_YELLOW" 1 "$RESET" "Host System (Default)"
  printf '  %b[%d]%b %s\n' "$TEXT_BRIGHT_YELLOW" 2 "$RESET" "Custom Image (BMP)"

  validate_bmp() {
    local -a h
    readarray -t h < <(od -An -v -j0 -N54 -t u1 -w1 "$1")

    # Parse Little Endian headers
    width=$(( h[18] + (h[19]<<8) + (h[20]<<16) + (h[21]<<24) ))
    height=$(( h[22] + (h[23]<<8) + (h[24]<<16) + (h[25]<<24) ))
    bit_depth=$(( h[28] + (h[29]<<8) ))
    compression=$(( h[30] + (h[31]<<8) + (h[32]<<16) + (h[33]<<24) ))

    # Validate: Magic BM, Depth 1/4/8/24, No Compression, Max 65535px
    if (( h[0] != 66 || h[1] != 77 || (bit_depth != 1 && bit_depth != 4 && bit_depth != 8 && bit_depth != 24) || compression != 0 || width > 65535 || height > 65535 )); then
      fmtr::error "Invalid BMP: ${width}x${height} @ ${bit_depth}bpp (Comp: ${compression})"
      return 1
    fi
  }

  while :; do
    read -rp "$(fmtr::ask 'Enter choice [1-2]: ')" logo_choice && : "${logo_choice:=1}"

    case "$logo_choice" in
      1)
        if [ -f /sys/firmware/acpi/bgrt/image ]; then
          cp /sys/firmware/acpi/bgrt/image MdeModulePkg/Logo/Logo.bmp \
            && fmtr::log "Host logo injected." \
            || fmtr::error "Copy failed."
        else
          fmtr::error "Host BGRT image missing."
        fi
        break
        ;;
      2)
        while :; do
          read -rp "$(fmtr::ask 'Path to BMP: ')" custom_bmp
          [ -f "$custom_bmp" ] || { fmtr::error "File not found."; continue; }

          if validate_bmp "$custom_bmp"; then
            fmtr::info "Valid BMP detected (${width}x${height})."
            cp "$custom_bmp" MdeModulePkg/Logo/Logo.bmp \
              && fmtr::log "Custom logo injected." \
              || fmtr::error "Copy failed."
            break 2
          fi
        done
        ;;
      *)
        fmtr::error "Invalid selection."
        ;;
    esac
  done
}





################################################################################
# Build OVMF w/SB & TPM
################################################################################
build_ovmf() {
  # --- Phase 1: Build Environment & Compilation ---
  fmtr::info "Initializing build environment..."

  export WORKSPACE="$(pwd)"
  export EDK_TOOLS_PATH="$WORKSPACE/BaseTools"
  export CONF_PATH="$WORKSPACE/Conf"

  if [[ ! -d BaseTools/Build ]]; then
    make -C BaseTools -j"$(nproc)" &>>"$LOG_FILE" || {
      fmtr::fatal "BaseTools build failed"; return 1;
    }
  fi

  source edksetup.sh &>>"$LOG_FILE" || {
    fmtr::fatal "edksetup.sh failed"; return 1;
  }

  build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC -b RELEASE -n 0 -s \
    -D SECURE_BOOT_ENABLE=TRUE -D SMM_REQUIRE=TRUE \
    -D TPM1_ENABLE=TRUE -D TPM2_ENABLE=TRUE &>>"$LOG_FILE" || {
      fmtr::fatal "OVMF build failed"; return 1;
    }

  # --- Phase 2: Variable Extraction & NVRAM Injection ---
  local efivars_json name guid path full_hex attr sep=""
  local -r build_fv="Build/OvmfX64/RELEASE_GCC/FV"
  local -r EFI_GLOBAL_VARIABLE=8be4df61-93ca-11d2-aa0d-00e098032b8c
  local -r EFI_IMAGE_SECURITY_DATABASE_GUID=d719b2cb-3d3a-4596-a3bc-dad00e67656f
  local -a keys=(
    "PK:$EFI_GLOBAL_VARIABLE"               "KEK:$EFI_GLOBAL_VARIABLE"
    "db:$EFI_IMAGE_SECURITY_DATABASE_GUID"  "dbx:$EFI_IMAGE_SECURITY_DATABASE_GUID"
    "PKDefault:$EFI_GLOBAL_VARIABLE"        "KEKDefault:$EFI_GLOBAL_VARIABLE"
    "dbDefault:$EFI_GLOBAL_VARIABLE"        "dbxDefault:$EFI_GLOBAL_VARIABLE"
  )

  efivars_json="$(mktemp)" || return 1
  trap 'rm -f "$efivars_json"' RETURN

  fmtr::info "Extracting host EFI keys..."

  {
    printf '{\n    "version": 2,\n    "variables": [\n'

    for entry in "${keys[@]}"; do
      IFS=: read -r name guid <<< "$entry"
      path="/sys/firmware/efi/efivars/${name}-${guid}"
      [[ -f "$path" ]] || continue

      full_hex=$(hexdump -ve '1/1 "%.2x"' "$path" 2>/dev/null) || continue
      attr=$(printf '%d' "0x${full_hex:6:2}${full_hex:4:2}${full_hex:2:2}${full_hex:0:2}")

      printf '%s        { "name": "%s", "guid": "%s", "attr": %d, "data": "%s" }' \
          "$sep" "$name" "$guid" "$attr" "${full_hex:8}"
      sep=$',\n'
    done

    printf '\n    ]\n}\n'
  } > "$efivars_json"

  fmtr::info "Populating OVMF NVRAM..."

  $ROOT_ESC cp "$build_fv/OVMF_CODE.fd" "$OUT_DIR/firmware/OVMF_CODE.fd" || return 1

  $ROOT_ESC virt-fw-vars \
    --input "$build_fv/OVMF_VARS.fd" \
    --output "$OUT_DIR/firmware/OVMF_VARS.fd" \
    --secure-boot \
    --set-json "$efivars_json" &>>"$LOG_FILE" || {
      fmtr::fatal "NVRAM injection failed"; return 1;
    }

  fmtr::log "Secure Boot provisioning complete."
}





################################################################################
# Cleanup
################################################################################
cleanup() {
  fmtr::info "Cleaning up..."
  rm -rf "$SRC_DIR/$EDK2_TAG"
  rmdir "$SRC_DIR" 2>/dev/null
}





################################################################################
# Main menu
################################################################################
main() {
  install_req_pkgs "EDK2"
  acquire_edk2_source
  prmt::yes_or_no "$(fmtr::ask "Build & install OVMF?")" && build_ovmf
  ! prmt::yes_or_no "$(fmtr::ask "Keep repository directory?")" && cleanup
}

main
