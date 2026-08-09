#!/usr/bin/env bash

source "$(dirname "$0")/../utils.sh" || { echo "Failed to load utilities module!"; exit 1; }





readonly SRC_DIR="$(pwd)/src"

readonly TKG_URI="https://github.com/Frogging-Family/linux-tkg.git"
readonly TKG_DIR="linux-tkg"

readonly KERNEL_MAJOR="7"
readonly KERNEL_MINOR="0"
readonly KERNEL_PATCH="latest"
readonly KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}-${KERNEL_PATCH}"

readonly REQUIRED_DISK_SPACE_GB="35"





check_disk_space() {
    local build_path="${1:-$(pwd)}"
    local required_kb=$((REQUIRED_DISK_SPACE_GB * 1024 * 1024))

    local available_kb
    available_kb=$(df --output=avail "$build_path" | tail -1)

    if (( available_kb < required_kb )); then
        fmtr::error "Insufficient disk space on $(pwd)."
        fmtr::error "Available: $((available_kb/1024/1024))GB, Required: ${REQUIRED_DISK_SPACE_GB}GB"
        exit 1
    fi
    fmtr::info "Disk space check passed."
}





acquire_tkg_source() {
    mkdir -p "$SRC_DIR" && cd "$SRC_DIR" || { fmtr::fatal "Failed to enter source dir: $SRC_DIR"; exit 1; }

    clone_repo() {
        fmtr::info "Cloning '$TKG_DIR' from '$TKG_URI'..."
        git clone --depth=1 "$TKG_URI" "$TKG_DIR" &>>"$LOG_FILE" \
        || { fmtr::fatal "Failed to clone repository!"; exit 1; }
        cd "$TKG_DIR" || { fmtr::fatal "Missing '$TKG_DIR' directory!"; exit 1; }

        # Disable -Werror to prevent build failures on newer compilers
        fmtr::info "Patching -Werror..."
        grep -RIl '\-Werror' . | xargs -r sed -i 's/-Werror=/-W/g; s/-Werror-/-W/g; s/-Werror/-W/g'
    }

    if [ -d "$TKG_DIR" ]; then
        fmtr::warn "Repository directory '$TKG_DIR' found."
        if prmt::yes_or_no "$(fmtr::ask "Purge '$TKG_DIR' directory?")"; then
        rm -rf "$TKG_DIR" || { fmtr::fatal "Failed to purge '$TKG_DIR' directory!"; exit 1; }
        fmtr::info "Directory purged successfully."
        if prmt::yes_or_no "$(fmtr::ask "Clone '$TKG_URI' again?")"; then
            clone_repo
        else
            fmtr::info "Skipping..."
        fi
        else
        fmtr::info "Skipping..."
        cd "$TKG_DIR" || { fmtr::fatal "Missing '$TKG_DIR' directory!"; exit 1; }
        fi
    else
        clone_repo
    fi
}





select_distro() {
    local options=("Arch" "Ubuntu" "Debian" "Fedora" "Suse" "Gentoo" "Generic")

    while true; do
        clear
        fmtr::info "Select Linux Distribution:\n"
        local i=1
        for opt in "${options[@]}"; do echo "  $i) $opt"; ((i++)); done

        local choice
        echo "" && read -p "  Enter choice [1-7]: " choice

        if [[ "$choice" -ge 1 && "$choice" -le 7 ]]; then
            _SELECTED_DISTRO="${options[$((choice-1))]}"
            echo "" && fmtr::info "Selected: $_SELECTED_DISTRO"
            break
        fi

        fmtr::error "Invalid option."
        prmt::quick_prompt "  Press any key to retry..." >/dev/null
    done
}





detect_and_select_cpu() {
    local -a architectures

    clear && fmtr::info "Detected CPU Manufacturer: $CPU_MANUFACTURER"

    case "$CPU_MANUFACTURER" in
        "AMD")
            architectures=(
                "k8" "k8sse3" "k10" "barcelona" "bobcat" "jaguar" "bulldozer" "piledriver"
                "steamroller" "excavator" "znver1" "znver2" "znver3" "znver4" "znver5" "native_amd"
            )
            ;;
        "Intel")
            architectures=(
                "mpsc" "atom" "core2" "nehalem" "westmere" "silvermont" "sandybridge" "ivybridge"
                "haswell" "broadwell" "skylake" "skylakex" "cannonlake" "icelake" "icelake_server"
                "goldmont" "goldmontplus" "cascadelake" "cooperlake" "tigerlake" "sapphirerapids"
                "rocketlake" "alderlake" "raptorlake" "meteorlake" "native_intel"
            )
            ;;
        *)
            fmtr::warn "Unsupported CPU Manufacturer: $CPU_MANUFACTURER. Defaulting to generic."
            _SELECTED_CPU_OPT="generic"
            return
            ;;
    esac

    while true; do
        fmtr::info "Select CPU μarch:\n\n  https://wikipedia.org/wiki/List_of_${CPU_MANUFACTURER}_CPU_microarchitectures\n"
        local i=1
        for arch in "${architectures[@]}"; do
            printf "  %2d) %s\n" "$i" "$arch"
            ((i++))
        done

        local choice
        echo "" && read -p "  Enter choice [1-${#architectures[@]}]: " choice

        if [[ "$choice" -ge 1 && "$choice" -le "${#architectures[@]}" ]]; then
            _SELECTED_CPU_OPT="${architectures[$((choice-1))]}"
            break
        fi

        fmtr::error "Invalid selection."
        prmt::quick_prompt "  Press any key to retry..." >/dev/null
    done
}





apply_tkg_config() {
    local acs_override="false"
    if prmt::yes_or_no "$(fmtr::ask_inline 'Enable ACS override patch (for IOMMU groups)?')"; then
        acs_override="true"
    fi

    declare -A config=(
        [_distro]="$_SELECTED_DISTRO"
        [_version]="$KERNEL_VERSION"
        [_EXT_CONFIG_PATH]=""
        [_menunconfig]="false"
        [_diffconfig]="false"
        [_cpusched]="eevdf"
        [_compiler]="gcc"
        [_sched_yield_type]="0"
        [_rr_interval]="2"
        [_tickless]="1"
        [_acs_override]="$acs_override"
        [_processor_opt]="$_SELECTED_CPU_OPT"
        [_timer_freq]="1000"
        [_user_patches_no_confirm]="true"
        [_force_all_threads]="true"
        [_modprobeddb]="false"
    )

    local sed_script=""
    for key in "${!config[@]}"; do
        sed_script+="s|^$key=.*|$key=\"${config[$key]}\"|;"
    done

    sed -i "$sed_script" "customization.cfg" || { fmtr::fatal "Failed to write configuration."; exit 1; }

    fmtr::info "Applied configuration to 'customization.cfg'"
}





patch_kernel_files() {
    local patch_name="zen-kernel-${KERNEL_MAJOR}.${KERNEL_MINOR}-${KERNEL_PATCH}-${CPU_MANUFACTURER}.mypatch"
    local user_patch_dir="linux${KERNEL_MAJOR}${KERNEL_MINOR}-tkg-userpatches"
    local source_patch="../../patches/Kernel/$patch_name"

    if [[ -f "$source_patch" ]]; then
        mkdir -p "$user_patch_dir"
        cp "$source_patch" "$user_patch_dir/"
        fmtr::info "Copied user patch: $patch_name"
    else
        fmtr::warn "Patch file not found: $source_patch"
    fi
}





create_systemd_boot_entry() {
    if ! prmt::yes_or_no "$(fmtr::ask_inline 'Create systemd-boot entry?')"; then
        return
    fi

    local kernel_tag="linux${KERNEL_MAJOR}${KERNEL_MINOR}-tkg-eevdf"
    local entry_name="HvP-RDTSC"
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

    # Find boot entry location
    local entry_dir=""
    for dir in "/boot/loader/entries" "/boot/efi/loader/entries" "/efi/loader/entries"; do
        if [[ -d "$dir" ]]; then entry_dir="$dir"; break; fi
    done
    [[ -z "$entry_dir" ]] && { fmtr::error "No systemd-boot directory found."; return 1; }

    local root_dev=$(findmnt -n -o SOURCE /)
    local partuuid=$(blkid -s PARTUUID -o value "${root_dev%\[*}")
    local fstype=$(findmnt -n -o FSTYPE /)
    local options="options root=PARTUUID=${partuuid} rw rootfstype=${fstype}"

    fmtr::info "Writing boot entries to $entry_dir (requires privileges)..."

    cat <<EOF | $ROOT_ESC tee "$entry_dir/$entry_name.conf" >/dev/null
# Created by: HvP-Script ($timestamp)
title   HvP (RDTSC Patch)
linux   /vmlinuz-$kernel_tag
initrd  /initramfs-$kernel_tag.img
$options
EOF

    cat <<EOF | $ROOT_ESC tee "$entry_dir/$entry_name-fallback.conf" >/dev/null
# Created by: HvP-Script ($timestamp)
title   HvP (RDTSC Patch - Fallback)
linux   /vmlinuz-$kernel_tag
initrd  /initramfs-$kernel_tag-fallback.img
$options
EOF

    fmtr::info "Boot entries created successfully."
}

build_arch() {
    fmtr::info "Starting Arch Linux build (makepkg)..."
    makepkg -C -si --noconfirm
    create_systemd_boot_entry
}

build_generic() {
    fmtr::info "Starting Generic build (install.sh)..."
    ./install.sh install
    create_systemd_boot_entry
}

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
    check_disk_space
    acquire_tkg_source
    select_distro
    detect_and_select_cpu
    apply_tkg_config
    # patch_kernel_files TODO

    if [[ "$_SELECTED_DISTRO" == "Arch" ]]; then
        build_arch
    else
        build_generic
    fi
}

main "$@"
