#!/usr/bin/env bash

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }

readonly VFIO_CONF_PATH="/etc/modprobe.d/vfio.conf"
readonly VFIO_KERNEL_OPTS_REGEX='(intel_iommu=[^ ]*|iommu=[^ ]*|vfio-pci\.ids=[^ ]*)'
readonly LIMINE_ENTRY_REGEX='^KERNEL_CMDLINE\[.*\]\+?='

readonly -a SDBOOT_CONF_LOCATIONS=(
    /boot/loader/entries
    /boot/efi/loader/entries
    /efi/loader/entries
)

declare -A GPU_DRIVERS=(
    ["0x10de"]="nouveau nvidia nvidia_drm"
    ["0x1002"]="amdgpu radeon"
    ["0x8086"]="i915 xe"
)

VFIO_PCI_IDS=""
BOOTLOADER_CHANGED=0

################################################################################
# Bootloader Detection
################################################################################
detect_bootloader() {
    # ── Limine Bootloader ────────────────────────────────────────────────
    if [[ -f /etc/default/limine ]]; then
        BOOTLOADER_TYPE=limine
        BOOTLOADER_CONFIG="/etc/default/limine"
        return 0
    fi

    # ── GRUB Bootloader ──────────────────────────────────────────────────
    if [[ -f /etc/default/grub ]]; then
        BOOTLOADER_TYPE=grub
        BOOTLOADER_CONFIG="/etc/default/grub"
        return 0
    fi

    # ── systemd-boot Bootloader ──────────────────────────────────────────
    for dir in "${SDBOOT_CONF_LOCATIONS[@]}"; do
        if [[ -d $dir ]]; then
            BOOTLOADER_TYPE=systemd-boot
            BOOTLOADER_CONFIG=$(find "$dir" -maxdepth 1 -type f -name '*.conf' ! -name '*-fallback.conf' -print -quit)
            [[ -z "$BOOTLOADER_CONFIG" ]] && {
                fmtr::warn "systemd-boot entry directory found ($dir) but contains no config files."
                continue
            }
            return 0
        fi
    done

    fmtr::error "No supported bootloader detected (Limine, GRUB, or systemd-boot). Exiting."
    return 1
}

################################################################################
# Revert VFIO Configurations
################################################################################
revert_vfio() {
    if [[ -f $VFIO_CONF_PATH ]]; then
        $ROOT_ESC rm -v "$VFIO_CONF_PATH" &>>"$LOG_FILE"
        fmtr::log "Removed VFIO Config: $VFIO_CONF_PATH"
    else
        fmtr::log "$VFIO_CONF_PATH doesn't exist; nothing to remove."
    fi

    case $BOOTLOADER_TYPE in
        grub)
            $ROOT_ESC sed -E -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
                s/'"$VFIO_KERNEL_OPTS_REGEX"'//g
                s/[[:space:]]+/ /g
                s/"[[:space:]]+/"
                s/[[:space:]]+"/"/
            }' "$BOOTLOADER_CONFIG"
            ;;
        systemd-boot)
            $ROOT_ESC sed -E -i "/^options / {
                s/$VFIO_KERNEL_OPTS_REGEX//g;
                s/[[:space:]]+/ /g;
                s/[[:space:]]+$//;
            }" "$BOOTLOADER_CONFIG"
            ;;
        limine)
            $ROOT_ESC sed -E -i "/${LIMINE_ENTRY_REGEX}/ {
                s/$VFIO_KERNEL_OPTS_REGEX//g;
                s/[[:space:]]+/ /g;
                s/\"[[:space:]]+\"/\"\"/;
            }" "$BOOTLOADER_CONFIG"
            ;;
    esac
    fmtr::log "Removed VFIO kernel opts from: $BOOTLOADER_CONFIG"
}

################################################################################
# Configure VFIO
################################################################################
configure_vfio() {
    local dev bdf desc sel target_bdf vendor_id device_id bad=0
    local -a gpus=() badf=() iommu_ids=()

    # Discover GPUs
    local -A lspci_map=()
    while IFS= read -r line; do
        lspci_map["${line%% *}"]="$line"
    done < <(lspci -D 2>/dev/null)

    for dev in /sys/bus/pci/devices/*; do
        read -r dev_class < "$dev/class"
        [[ $dev_class == 0x03* ]] || continue
        bdf=${dev##*/}
        desc=${lspci_map[$bdf]:-}
        [[ -n "$desc" ]] || continue
        desc=${desc##*[}; desc=${desc%%]*}
        gpus+=("$bdf|$desc")
    done

    (( ${#gpus[@]} )) || { fmtr::error "No GPUs detected!"; return 1; }
    (( ${#gpus[@]} == 1 )) && fmtr::warn "Only one GPU detected! Passing it through will leave the host without display output."

    # GPU selection
    local select_prompt
    select_prompt=$(fmtr::ask 'Select device number: ')
    while :; do
        for dev in "${!gpus[@]}"; do printf '\n  %d) %s\n' "$((dev+1))" "${gpus[dev]#*|}"; done
        read -rp "$select_prompt" sel
        (( sel >= 1 && sel <= ${#gpus[@]} )) 2>/dev/null && break
        fmtr::error "Invalid selection. Please choose a valid number."
    done

    target_bdf="${gpus[sel-1]%%|*}"
    local iommu_group_path
    iommu_group_path=$(readlink -f "/sys/bus/pci/devices/$target_bdf/iommu_group")
    local iommu_group=${iommu_group_path##*/}

    # Collect device IDs & validate IOMMU group isolation
    local target_vendor
    for dev in "/sys/kernel/iommu_groups/$iommu_group/devices/"*; do
        bdf=${dev##*/}
        read -r vendor_id < "$dev/vendor" || continue
        read -r device_id < "$dev/device" || continue
        iommu_ids+=("${vendor_id#0x}:${device_id#0x}")
        [[ $bdf == "$target_bdf" ]] && target_vendor="$vendor_id"
        [[ $bdf == "${target_bdf%.*}".* ]] || { bad=1; badf+=("$bdf"); }
    done

    if (( bad )); then
        printf -v bad_devs '  [%s]\n' "${badf[@]}"
        fmtr::error "Detected poor IOMMU grouping! IOMMU group #$iommu_group contains:\n\n${bad_devs}"
        fmtr::warn "VFIO PT requires full group isolation. Possible solutions:
      BIOS update, ACS override kernel patch, or new motherboard."
        return 1
    fi

    VFIO_PCI_IDS=$(IFS=,; echo "${iommu_ids[*]}")

    # Write VFIO config
    fmtr::log "Modifying VFIO config: $VFIO_CONF_PATH"

    {
        printf 'options vfio-pci ids=%s disable_vga=1\n' "$VFIO_PCI_IDS"
        for soft in ${GPU_DRIVERS[$target_vendor]:-}; do printf 'softdep %s pre: vfio-pci\n' "$soft"; done
    } | $ROOT_ESC tee "$VFIO_CONF_PATH" >> "$LOG_FILE"

    # sudo sed -i 's/^MODULES=()$/MODULES=(vfio vfio_iommu_type1 vfio_pci)/' /etc/mkinitcpio.conf
    # sudo mkinitcpio -P
}

################################################################################
# Bootloader Configuration
################################################################################
configure_bootloader() {
    local -a kernel_opts
    kernel_opts=( "iommu=pt" "vfio-pci.ids=${VFIO_PCI_IDS}" )
    [[ "$CPU_VENDOR_ID" == "GenuineIntel" ]] && kernel_opts=( "intel_iommu=on" "${kernel_opts[@]}" )

    local kernel_opts_str="${kernel_opts[*]}"

    case $BOOTLOADER_TYPE in
        grub)
            fmtr::log "Configuring GRUB: $BOOTLOADER_CONFIG"

            if ! grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=.*${kernel_opts[1]}" "$BOOTLOADER_CONFIG"; then
                $ROOT_ESC sed -E -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ {
                    s/^GRUB_CMDLINE_LINUX_DEFAULT=//;
                    s/^\"//; s/\"$//;
                    s/$VFIO_KERNEL_OPTS_REGEX//g;
                    s/[[:space:]]+/ /g;
                    s/[[:space:]]+$//;
                    s|^|GRUB_CMDLINE_LINUX_DEFAULT=\"|;
                    s|$| ${kernel_opts_str}\"|;
                }" "$BOOTLOADER_CONFIG"

                fmtr::log "Inserted new VFIO kernel opts into GRUB config."
                BOOTLOADER_CHANGED=1
            else
                fmtr::log "VFIO kernel opts already present in GRUB config. Skipping."
            fi
            ;;
        systemd-boot)
            fmtr::log "Modifying systemd-boot config: $BOOTLOADER_CONFIG"

            $ROOT_ESC sed -E -i "/^options / {
                s/$VFIO_KERNEL_OPTS_REGEX//g;
                s/[[:space:]]+/ /g;
                s/[[:space:]]+$//;
            }" "$BOOTLOADER_CONFIG"

            if ! grep -q -E "^options .*${kernel_opts[1]}" "$BOOTLOADER_CONFIG"; then
                $ROOT_ESC sed -E -i -e "/^options / s/$/ ${kernel_opts_str}/" "$BOOTLOADER_CONFIG"
                fmtr::log "Appended VFIO kernel opts to systemd-boot config."
            else
                fmtr::log "VFIO kernel opts already present in systemd-boot config. Skipping append."
            fi
            ;;
        limine)
            fmtr::log "Modifying Limine config: $BOOTLOADER_CONFIG"

            $ROOT_ESC sed -E -i "/${LIMINE_ENTRY_REGEX}/ {
                s/$VFIO_KERNEL_OPTS_REGEX//g;
                s/[[:space:]]+/ /g;
            }" "$BOOTLOADER_CONFIG"

            if ! grep -E "${LIMINE_ENTRY_REGEX}" "$BOOTLOADER_CONFIG" | grep -q "${kernel_opts[1]}"; then
                $ROOT_ESC sed -E -i "/${LIMINE_ENTRY_REGEX}/ s/\"$/ ${kernel_opts_str}\"/" "$BOOTLOADER_CONFIG"
                fmtr::log "Appended VFIO kernel opts to all Limine kernel entries."
            else
                fmtr::log "VFIO kernel opts already present in Limine config. Skipping append."
            fi
            ;;
    esac
}

################################################################################
# Rebuild Bootloader Configuration
################################################################################
rebuild_bootloader() {
    case $BOOTLOADER_TYPE in
        grub)
            fmtr::log "Updating bootloader configuration for GRUB."

            local cmd cfg
            for cmd in grub-mkconfig grub2-mkconfig; do
                command -v "$cmd" &>>"$LOG_FILE" || continue
                cfg="/boot/${cmd%-mkconfig}/grub.cfg"
                $ROOT_ESC "$cmd" -o "$cfg" &>>"$LOG_FILE" && { fmtr::log "Bootloader configuration updated."; return; }
            done

            fmtr::error "No known GRUB configuration command found on this system."
            return 1
            ;;
        limine)
            fmtr::log "Updating bootloader configuration for Limine."

            if command -v limine-mkinitcpio &>>"$LOG_FILE"; then
                $ROOT_ESC limine-mkinitcpio &>>"$LOG_FILE" && { fmtr::log "Bootloader configuration updated."; return; }
                fmtr::error "limine-mkinitcpio failed."
                return 1
            fi

            fmtr::error "limine-mkinitcpio command not found on this system."
            return 1
            ;;
        *)
            fmtr::error "No supported bootloader type set for rebuild (GRUB or Limine)."
            return 1
            ;;
    esac
}

################################################################################
# Main Script
################################################################################
detect_bootloader || exit 1

# Prompt 1 - Remove VFIO config?
prmt::yes_or_no "$(fmtr::ask 'Remove GPU PT/VFIO configs?')" && revert_vfio

# Prompt 2 - Configure VFIO config?
if prmt::yes_or_no "$(fmtr::ask 'Configure GPU PT/VFIO now?')"; then
    configure_vfio || { fmtr::log "Configuration aborted during device selection."; exit 1; }
    configure_bootloader || { fmtr::log "Bootloader configuration aborted."; exit 1; }
fi

# Prompt 3 - Rebuild bootloader config?
if [[ "$BOOTLOADER_TYPE" == "systemd-boot" ]]; then
    fmtr::log "Detected systemd-boot; no bootloader rebuild required (config is applied directly)."
elif (( ! BOOTLOADER_CHANGED )); then
    fmtr::log "No changes detected in bootloader config; skipping rebuild prompt."
elif prmt::yes_or_no "$(fmtr::ask "Proceed with rebuilding $BOOTLOADER_TYPE bootloader config?")"; then
    rebuild_bootloader || { fmtr::log "Failed to update bootloader configuration."; exit 1; }
    fmtr::warn "REBOOT required for changes to take effect"
else
    fmtr::warn "Proceeding without updating bootloader."
fi
