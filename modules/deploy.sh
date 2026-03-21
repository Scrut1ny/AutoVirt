#!/usr/bin/env bash

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }

readonly OUT_DIR="/opt/AutoVirt"
readonly SMBIOS_SCRIPT="$(pwd)/resources/scripts/Linux/SMBIOS.py"

# Debug helper — prints variable name + value when DEBUG=1
dbg::var() {
    [[ "${DEBUG:-0}" == "1" ]] || return 0
    local name=$1 val=$2
    fmtr::info "[DEBUG] $name = '$val'"
}

dbg::step() {
    [[ "${DEBUG:-0}" == "1" ]] || return 0
    fmtr::info "[DEBUG] $*"
}

system_info() {
    # Domain Name
    DOMAIN_NAME="AutoVirt"

    # CPU Topology
    HOST_LOGICAL_CPUS=$(nproc --all 2>/dev/null || nproc 2>/dev/null)
    HOST_CORES_PER_SOCKET=$(LC_ALL=C lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p')
    HOST_THREADS_PER_CORE=$(LC_ALL=C lscpu | sed -n 's/^Thread(s) per core:[[:space:]]*//p')

    dbg::step "Detecting CPU topology..."
    dbg::var "HOST_LOGICAL_CPUS" "$HOST_LOGICAL_CPUS"
    dbg::var "HOST_CORES_PER_SOCKET" "$HOST_CORES_PER_SOCKET"
    dbg::var "HOST_THREADS_PER_CORE" "$HOST_THREADS_PER_CORE"

    # Validate CPU topology values
    if [[ -z "$HOST_CORES_PER_SOCKET" || -z "$HOST_THREADS_PER_CORE" ]]; then
        fmtr::error "Failed to detect CPU topology (cores=$HOST_CORES_PER_SOCKET, threads=$HOST_THREADS_PER_CORE)."
        fmtr::error "Falling back to: 1 socket, $HOST_LOGICAL_CPUS cores, 1 thread."
        HOST_CORES_PER_SOCKET="$HOST_LOGICAL_CPUS"
        HOST_THREADS_PER_CORE="1"
    fi

    # MAC Address (Uses host's OUI with fallback)
    dbg::step "Detecting network interface for MAC OUI..."
    UPLINK_IFACE=""
    if command -v nmcli &>/dev/null; then
        UPLINK_IFACE=$(nmcli -t device show 2>/dev/null | awk -F: '
        /^GENERAL.DEVICE/ {dev=$2}
        /^GENERAL.TYPE/   {type=$2}
        /^IP4.GATEWAY/ && $2!="" && type!="wireguard" {print dev; exit}
        ')
        dbg::var "UPLINK_IFACE (nmcli)" "$UPLINK_IFACE"
    fi

    # Fallback: use ip route to find default interface
    if [[ -z "$UPLINK_IFACE" ]]; then
        dbg::step "nmcli failed or unavailable, trying 'ip route' fallback..."
        UPLINK_IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        dbg::var "UPLINK_IFACE (ip route)" "$UPLINK_IFACE"
    fi

    if [[ -n "$UPLINK_IFACE" && -f "/sys/class/net/$UPLINK_IFACE/address" ]]; then
        OUI=$(cat /sys/class/net/"$UPLINK_IFACE"/address | awk -F: '{print $1 ":" $2 ":" $3}')
    else
        fmtr::warn "Could not detect network interface. Using random OUI for MAC address."
        OUI=$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    fi
    RANDOM_MAC="$OUI:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    dbg::var "RANDOM_MAC" "$RANDOM_MAC"

    # Random 20-char hex serial (A-F0-9)
    DRIVE_SERIAL="$(LC_ALL=C tr -dc 'A-F0-9' </dev/urandom | head -c 20)"

    # Random WWN (World Wide Name) - 16 hex chars, typically starts with 5 for NAA
    # DRIVE_WWN="0x5$(LC_ALL=C tr -dc '0-9a-f' </dev/urandom | head -c 15)"

    # Memory selection (MiB)
    local mem_choice
    while :; do
        fmtr::log "Memory allocation:

  1) 8  GiB  (8192  MiB)
  2) 12 GiB  (12288 MiB)
  3) 16 GiB  (16384 MiB)
  4) 24 GiB  (24576 MiB)
  5) 32 GiB  (32768 MiB)
  6) 64 GiB  (65536 MiB)"

        read -r -p "$(fmtr::ask_inline "Choose an option [1-6]: ")" mem_choice
        printf '%s\n' "$mem_choice" >>"$LOG_FILE"

        case "$mem_choice" in
            1) HOST_MEMORY_MIB=8192  ;;
            2) HOST_MEMORY_MIB=12288 ;;
            3) HOST_MEMORY_MIB=16384 ;;
            4) HOST_MEMORY_MIB=24576 ;;
            5) HOST_MEMORY_MIB=32768 ;;
            6) HOST_MEMORY_MIB=65536 ;;
            *) fmtr::warn "Invalid option. Please choose 1–6."; continue ;;
        esac

        fmtr::info "Selected #$mem_choice ($HOST_MEMORY_MIB MiB)"
        break
    done

    # ISO Selection
    DOWNLOADS_DIR="/home/$USER/Downloads"
    ISO_PATH=""

    ensure_permissions() {
        local target_path="$1"
        local username="libvirt-qemu"
        local dirs_to_check=()

        local current_dir="$target_path"
        while [[ "$current_dir" != "/" && "$current_dir" != "/home" ]]; do
            dirs_to_check+=("$current_dir")
            current_dir="$(dirname "$current_dir")"
        done

        for ((i=${#dirs_to_check[@]}-1; i>=0; i--)); do
            local dir="${dirs_to_check[$i]}"

            # Check if libvirt-qemu already has access via ACL
            if getfacl "$dir" 2>/dev/null | grep -q "user:$username:.*x"; then
                continue
            fi

            # Check if directory is already world-executable
            if [[ -x "$dir" ]]; then
                continue
            fi

            # Try setting ACL first (preferred - more granular)
            if command -v setfacl &> /dev/null; then
                if $ROOT_ESC setfacl --modify "user:$username:x" "$dir" 2>/dev/null; then
                    fmtr::info "Set ACL execute permission for $username on $dir"
                    continue
                fi
            fi

            # Fallback to chmod o+x
            if $ROOT_ESC chmod o+x "$dir" 2>/dev/null; then
                fmtr::info "Set world-execute permission on $dir"
                continue
            fi

            fmtr::warn "Failed to set permissions on $dir"
            return 1
        done

        return 0
    }

    if ! ensure_permissions "$DOWNLOADS_DIR"; then
        fmtr::fatal "Failed to set proper permissions for libvirt-qemu on $DOWNLOADS_DIR or its parent directories."
        exit 1
    fi

    mapfile -d '' -t ISO_FILES < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -iname '*.iso' -print0 | sort -z)

    if (( ${#ISO_FILES[@]} == 0 )); then
        fmtr::fatal "No .iso files found in $DOWNLOADS_DIR"
        exit 1
    fi

    while :; do
        menu="Available ISOs ($DOWNLOADS_DIR):\n"
        for i in "${!ISO_FILES[@]}"; do
            menu+="\n  $((i+1))) $(basename -- "${ISO_FILES[$i]}")"
        done
        fmtr::log "$menu"

        read -r -p "$(fmtr::ask_inline "Choose an ISO [1-${#ISO_FILES[@]}]: ")" ISO_CHOICE
        printf '%s\n' "$ISO_CHOICE" >>"$LOG_FILE"

        [[ "$ISO_CHOICE" =~ ^[0-9]+$ ]] || { fmtr::warn "Please enter a number."; continue; }
        (( ISO_CHOICE >= 1 && ISO_CHOICE <= ${#ISO_FILES[@]} )) || { fmtr::warn "Choice out of range."; continue; }

        ISO_PATH="${ISO_FILES[$((ISO_CHOICE-1))]}"
        fmtr::info "Selected ISO #$ISO_CHOICE: $(basename -- "$ISO_PATH")"
        break
    done

    if grep -a -m1 -q '10\.0\.2[2-9]' "$ISO_PATH"; then
        WIN_VERSION="win11"
    else
        WIN_VERSION="win10"
    fi
    fmtr::info "Detected Windows ISO version: $WIN_VERSION"
    dbg::var "WIN_VERSION" "$WIN_VERSION"
    dbg::var "DRIVE_SERIAL" "$DRIVE_SERIAL"
    dbg::var "ISO_PATH" "$ISO_PATH"
}

# Generate smbios.bin from host firmware tables
generate_smbios() {
    local target="$OUT_DIR/firmware/smbios.bin"

    if [[ -f "$target" ]]; then
        fmtr::info "smbios.bin already exists at $target"
        return 0
    fi

    if [[ ! -f "$SMBIOS_SCRIPT" ]]; then
        fmtr::error "SMBIOS.py script not found at: $SMBIOS_SCRIPT"
        fmtr::error "Cannot generate smbios.bin — VM may be detectable as virtual."
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        fmtr::error "python3 not found — cannot generate smbios.bin"
        return 1
    fi

    fmtr::info "Generating smbios.bin from host firmware tables..."
    local tmpdir
    tmpdir=$(mktemp -d) || { fmtr::error "Failed to create temp directory"; return 1; }

    if (cd "$tmpdir" && $ROOT_ESC python3 "$SMBIOS_SCRIPT") &>>"$LOG_FILE"; then
        if [[ -f "$tmpdir/smbios.bin" ]]; then
            $ROOT_ESC mv "$tmpdir/smbios.bin" "$target" && \
            $ROOT_ESC chmod 0644 "$target" && \
            fmtr::log "Generated smbios.bin at $target"
        else
            fmtr::error "SMBIOS.py ran but did not produce smbios.bin"
            rm -rf "$tmpdir"
            return 1
        fi
    else
        fmtr::error "SMBIOS.py failed (check $LOG_FILE)"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

# Check that all required files exist before deploying
check_prerequisites() {
    local ok=0

    fmtr::info "Checking prerequisites..."

    # Check patched QEMU binary
    if [[ ! -x "$OUT_DIR/emulator/bin/qemu-system-x86_64" ]]; then
        fmtr::error "Patched QEMU binary not found at: $OUT_DIR/emulator/bin/qemu-system-x86_64"
        fmtr::error "  ➜ Run option [2] 'QEMU (Patched) Setup' first."
        ok=1
    else
        dbg::step "✓ Patched QEMU binary found"
    fi

    # Check OVMF firmware files
    if [[ ! -f "$OUT_DIR/firmware/OVMF_CODE.fd" ]]; then
        fmtr::error "OVMF_CODE.fd not found at: $OUT_DIR/firmware/OVMF_CODE.fd"
        fmtr::error "  ➜ Run option [3] 'EDK2 (Patched) Setup' first."
        ok=1
    else
        dbg::step "✓ OVMF_CODE.fd found"
    fi

    if [[ ! -f "$OUT_DIR/firmware/OVMF_VARS.fd" ]]; then
        fmtr::error "OVMF_VARS.fd not found at: $OUT_DIR/firmware/OVMF_VARS.fd"
        fmtr::error "  ➜ Run option [3] 'EDK2 (Patched) Setup' first."
        ok=1
    else
        dbg::step "✓ OVMF_VARS.fd found"
    fi

    # Generate smbios.bin if needed
    generate_smbios || ok=1

    if [[ ! -f "$OUT_DIR/firmware/smbios.bin" ]]; then
        fmtr::warn "smbios.bin not found — --qemu-commandline smbios flag will be skipped."
        SMBIOS_AVAILABLE=0
    else
        dbg::step "✓ smbios.bin found"
        SMBIOS_AVAILABLE=1
    fi

    # Check libvirtd is running
    if ! systemctl is-active --quiet libvirtd.socket 2>/dev/null && \
       ! systemctl is-active --quiet libvirtd.service 2>/dev/null; then
        fmtr::error "libvirtd is not running! Start it with: sudo systemctl start libvirtd.socket"
        ok=1
    else
        dbg::step "✓ libvirtd is running"
    fi

    # Check default network
    if ! $ROOT_ESC virsh net-info default &>/dev/null; then
        fmtr::warn "Default libvirt network not found. Network may not work."
    else
        dbg::step "✓ Default libvirt network available"
    fi

    return $ok
}

configure_xml() {
    if $ROOT_ESC virsh dominfo "$DOMAIN_NAME" >/dev/null 2>&1; then
        fmtr::fatal "Domain '$DOMAIN_NAME' already exists. Please delete it before running this script."
        fmtr::info "  To remove it: sudo virsh undefine '$DOMAIN_NAME' --nvram"
        return 1
    fi

    # Run prerequisite checks
    check_prerequisites || {
        fmtr::fatal "Prerequisite checks failed. Please resolve the issues above before deploying."
        return 1
    }

    ################################################################################
    #
    # Hyper-V
    #

    local HYPERV_ARGS=()
    local enable_hyperv=""

    while :; do
        read -r -p "$(fmtr::ask_inline "Enable Hyper-V? [y/n]: ")" enable_hyperv
        printf '%s\n' "$enable_hyperv" >>"$LOG_FILE"

        case "$enable_hyperv" in
            [Yy]*)
                # KVM nested check (Intel or AMD)
                nested_file=(/sys/module/kvm_*/parameters/nested)
                
                if [[ -f ${nested_file[0]} ]]; then
                    read -r nested < "${nested_file[0]}"
                    if [[ "$nested" != "Y" && "$nested" != "1" ]]; then
                        mod=${nested_file[0]#/sys/module/}; mod=${mod%%/*}
                        fmtr::warn "Hyper-V requires nested virtualization."
                        fmtr::warn "Run: sudo modprobe -r $mod && sudo modprobe $mod nested=1"
                        continue
                    fi
                fi
                
                HYPERV_ARGS=('--xml' "./features/hyperv/@mode=passthrough")
                HYPERV_CLOCK_STATUS="yes"
                CPU_FEATURE_HYPERVISOR="optional"
                fmtr::info "Setting Hyper-V to passthrough mode."
                break
                ;;
            [Nn]*)
                HYPERV_ARGS=('--xml' "xpath.delete=./features/hyperv")
                HYPERV_CLOCK_STATUS="no"
                CPU_FEATURE_HYPERVISOR="disable"
                fmtr::info "Disabling all Hyper-V related settings."
                break
                ;;
            *)
                fmtr::warn "Please answer y or n."
                continue
                ;;
        esac
    done

    ################################################################################
    #
    # EVDEV
    #

    local EVDEV_ARGS=()
    local enable_evdev=""

    while :; do
        read -r -p "$(fmtr::ask_inline "Configure evdev? [y/n]: ")" enable_evdev
        printf '%s\n' "$enable_evdev" >>"$LOG_FILE"

        case "$enable_evdev" in
            [Yy]*)
                local grab_toggle=""
                while :; do
                    fmtr::log "Available grabToggle combinations:

  1) ctrl-ctrl    4) meta-meta
  2) alt-alt      5) scrolllock
  3) shift-shift  6) ctrl-scrolllock"

                    read -r -p "$(fmtr::ask_inline "Choose an option [1-6]: ")" grab_toggle
                    printf '%s\n' "$grab_toggle" >>"$LOG_FILE"

                    case "$grab_toggle" in
                        1) grab_toggle="ctrl-ctrl" ;;
                        2) grab_toggle="alt-alt" ;;
                        3) grab_toggle="shift-shift" ;;
                        4) grab_toggle="meta-meta" ;;
                        5) grab_toggle="scrolllock" ;;
                        6) grab_toggle="ctrl-scrolllock" ;;
                        *) fmtr::warn "Invalid option. Please choose 1-6."; continue ;;
                    esac
                    break
                done

                declare -A seen_devices

                for dev in /dev/input/by-{id,path}/*-event-{kbd,mouse}; do
                    # Deduplicate by real path
                    real_dev=$(readlink -f "$dev") || continue
                    [[ -n "${seen_devices[$real_dev]}" ]] && continue
                    seen_devices["$real_dev"]=1

                    # Keyboard specific config
                    extra_config=""
                    [[ "$dev" == *"-event-kbd" ]] && extra_config=",source.grab=all,source.repeat=on"

                    # Single append operation
                    EVDEV_ARGS+=('--input' "type=evdev,source.dev=$dev,source.grabToggle=$grab_toggle${extra_config}")
                done

                fmtr::info "Evdev passthrough enabled."
                break
                ;;
            [Nn]*)
                fmtr::info "Evdev input passthrough disabled."
                break
                ;;
            *)
                fmtr::warn "Please answer y or n."
                ;;
        esac
    done

    ################################################################################
    #
    # Audio
    #

    local AUDIO_ARGS=()
    local enable_audio=""

    while :; do
        read -r -p "$(fmtr::ask_inline "Enable PipeWire audio passthrough (input + output)? [y/n]: ")" enable_audio
        printf '%s\n' "$enable_audio" >>"$LOG_FILE"

        case "$enable_audio" in
            [Yy]*)
                AUDIO_ARGS=(
                    '--sound' 'model=ich9,audio.id=1'
                    '--xml' './devices/audio/@id=1'
                    '--xml' './devices/audio/@type=pipewire'
                    '--xml' "./devices/audio/@runtimeDir=/run/user/$(id -u)"
                    '--xml' './devices/audio/input/@mixingEngine=no'
                    '--xml' './devices/audio/output/@mixingEngine=no'
                )
                fmtr::info "PipeWire audio enabled (low-latency mode)."
                break
                ;;
            [Nn]*)
                fmtr::info "Audio passthrough disabled."
                break
                ;;
            *)
                fmtr::warn "Please answer y or n."
                ;;
        esac
    done

    local -a args=(
        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#element-and-attribute-overview
        #

        --connect qemu:///system
        --name "$DOMAIN_NAME"
        --osinfo "$WIN_VERSION"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#memory-allocation
        #
        # Allocate realistic memory amounts, such as 8, 16, 32, and 64.
        #

        --memory "$HOST_MEMORY_MIB"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#operating-system-booting
        #

        # Boot order & menu | Loader/OVMF_CODE | NVRAM/OVMF_VARS
        --boot "cdrom,hd,menu=on,loader=/opt/AutoVirt/firmware/OVMF_CODE.fd,loader.readonly=yes,loader.secure=yes,loader.type=pflash,nvram.template=/opt/AutoVirt/firmware/OVMF_VARS.fd"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#hypervisor-features
        #

        "${HYPERV_ARGS[@]}"

        --features "kvm.hidden.state=on"  # CONCEALMENT: Hide the KVM hypervisor from standard MSR based discovery (CPUID Bitset)
        --features "pmu.state=off"        # CONCEALMENT: Disables the Performance Monitoring Unit (PMU)
        --features "vmport.state=off"     # CONCEALMENT: Disables the VMware I/O port backdoor (VMPort, 0x5658) in the guest | FYI: ACE AC looks for this
        --features "smm.state=on"         # Secure boot requires SMM feature enabled
        --features "msrs.unknown=fault"   # CONCEALMENT: Injects a #GP(0) into the guest on RDMSR/WRMSR to an unhandled/unknown MSR
        --xml "./features/ps2/@state=off" # CONCEALMENT: Disable PS/2 controller emulation





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#cpu-model-and-topology
        #

        --cpu "host-passthrough,topology.sockets=1,topology.cores=$HOST_CORES_PER_SOCKET,topology.threads=$HOST_THREADS_PER_CORE"

        --xml "./cpu/@check=none"
        --xml "./cpu/@migratable=off"
        --xml "./cpu/topology/@dies=1"
        --xml "./cpu/topology/@clusters=1"
        --xml "./cpu/cache/@mode=passthrough"
        --xml "./cpu/maxphysaddr/@mode=passthrough"

        # TODO: Make this change based on if user is on AMD or Intel

        --xml "./cpu/feature[@name='$CPU_VIRTUALIZATION']/@policy=optional"       # OPTIMIZATION: Enables AMD SVM (CPUID.80000001:ECX[2])
        --xml "./cpu/feature[@name='topoext']/@policy=optional"                   # OPTIMIZATION: Exposes extended topology (CPUID.80000001:ECX[22], CPUID.8000001E)
        --xml "./cpu/feature[@name='invtsc']/@policy=optional"                    # OPTIMIZATION: Provides invariant TSC (CPUID.80000007:EDX[8])
        --xml "./cpu/feature[@name='hypervisor']/@policy=$CPU_FEATURE_HYPERVISOR" # CONCEALMENT: Clears Hypervisor Present bit (CPUID.1:ECX[31])
        --xml "./cpu/feature[@name='ssbd']/@policy=disable"                       # CONCEALMENT: Clears Speculative Store Bypass Disable (CPUID.7.0:EDX[31])
        --xml "./cpu/feature[@name='amd-ssbd']/@policy=disable"                   # CONCEALMENT: Clears AMD SSBD flag (CPUID.80000008:EBX[25])
        --xml "./cpu/feature[@name='virt-ssbd']/@policy=disable"                  # CONCEALMENT: Clears virtual SSBD exposure (CPUID.7.0:EDX[31])





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#time-keeping
        #

        --xml "./clock/@offset=localtime"
        --xml "./clock/timer[@name='tsc']/@present=yes"
        --xml "./clock/timer[@name='tsc']/@mode=native"
        #--xml "./clock/timer[@name='hpet']/@present=yes"
        --xml "./clock/timer[@name='kvmclock']/@present=no"                      # CONCEALMENT: Disable KVM paravirtual clock source
        --xml "./clock/timer[@name='hypervclock']/@present=$HYPERV_CLOCK_STATUS" # CONCEALMENT: Disable Hyper-V paravirtual clock source





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#power-management
        #

        --xml "./pm/suspend-to-mem/@enabled=yes"  # CONCEALMENT: Enables S3 ACPI sleep state (suspend-to-RAM) support in the guest
        --xml "./pm/suspend-to-disk/@enabled=yes" # CONCEALMENT: Enables S4 ACPI sleep state (suspend-to-disk/hibernate) support in the guest





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#devices
        #
        # 'qemu-system-x86_64' binary path
        #

        --xml "./devices/emulator=/opt/AutoVirt/emulator/bin/qemu-system-x86_64"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#hard-drives-floppy-disks-cdroms
        #   - https://www.qemu.org/docs/master/system/devices/nvme.html
        #

        # TODO: Add user choice of using virtual drive, virtual drive + passthrough, complete PCI passthrough.
        # TODO: passthrough physical drive
        # --disk type=block,device=disk,source=/dev/nvme0n1,driver.name=qemu,driver.type=raw,driver.cache=none,driver.io=native,target.dev=nvme0,target.bus=nvme,serial=1233659 \

        # set & spoof eui64
        --disk "size=500,bus=nvme,serial=$DRIVE_SERIAL,driver.cache=none,driver.io=native,driver.discard=unmap,blockio.logical_block_size=4096,blockio.physical_block_size=4096"
        --check "disk_size=off"

        --cdrom "$ISO_PATH"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#network-interfaces
        #

        --network "network=default,model=e1000e,mac=$RANDOM_MAC"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#input-devices
        #

        --input "mouse,bus=usb"    # USB mouse instead of PS2
        --input "keyboard,bus=usb" # USB keyboard instead of PS2

        "${EVDEV_ARGS[@]}"         # Evdev configuration





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#sound-devices
        #   - https://libvirt.org/formatdomain.html#audio-devices
        #   - https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Passing_audio_from_virtual_machine_to_host_via_PipeWire_directly
        #

        "${AUDIO_ARGS[@]}"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#tpm-device
        #
        # TPM emulation requires the 'swtpm' package to function properly.
        #
        # TODO: Add option for user to passthrough TPM or emulate it
        #

        --tpm "backend.type=emulator,model=tpm-crb"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#graphical-framebuffers
        #
        # TODO: Set to 'none' once using external display method.
        #

        --graphics "spice"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#video-devices
        #
        # TODO: Set to 'none' once using external display method.
        #

        --video "vga"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#memory-balloon-device
        #
        # The VirtIO memballoon device enables the host to dynamically reclaim memory from your VM by growing the
        # balloon inside the guest, reserving reclaimed memory. Libvirt adds this device to guests by default.
        #
        # However, this device causes major performance issues with VFIO passthrough setups, and should be disabled.
        #

        --memballoon "none"





        ################################################################################
        #
        # Documentation:
        #   - https://libvirt.org/formatdomain.html#consoles-serial-parallel-channel-devices
        #

        --console "none" # Removed because added by default
        --channel "none" # Removed because added by default





        ################################################################################
        #
        # Documentation:
        #   - https://www.libvirt.org/kbase/qemu-passthrough-security.html
        #   - https://www.qemu.org/docs/master/system/qemu-manpage.html#hxtool-4
        #

        $(if (( SMBIOS_AVAILABLE )); then echo "--qemu-commandline=-smbios file=/opt/AutoVirt/firmware/smbios.bin"; fi)





        ################################################################################
        #
        # Miscellaneous Options:
        #

        --noautoconsole
        --wait 0
    )
    # https://man.archlinux.org/man/virt-install.1
    # sudo virt-install --features help

    # Debug: dump the full virt-install command
    dbg::step "virt-install command:"
    if [[ "${DEBUG:-0}" == "1" ]]; then
        printf '  %s\n' "${args[@]}" >> "$LOG_FILE"
        fmtr::info "[DEBUG] Full args written to $LOG_FILE"
    fi

    fmtr::info "Running virt-install... (this may take a moment)"

    # Capture stderr separately so we can show errors to the user
    local virt_stderr
    virt_stderr=$(mktemp) || { fmtr::error "Failed to create temp file"; return 1; }

    $ROOT_ESC virt-install "${args[@]}" >>"$LOG_FILE" 2>"$virt_stderr"
    local rc=$?

    # Always append stderr to log
    cat "$virt_stderr" >> "$LOG_FILE"

    if [[ $rc -ne 0 ]]; then
        fmtr::error "virt-install FAILED (exit code: $rc)!"
        fmtr::error "─── Error output ───"
        while IFS= read -r line; do
            [[ -n "$line" ]] && fmtr::error "  $line"
        done < "$virt_stderr"
        fmtr::error "────────────────────"
        fmtr::error "Full log: $LOG_FILE"
        rm -f "$virt_stderr"
        return 1
    fi

    rm -f "$virt_stderr"

    fmtr::log "VM '$DOMAIN_NAME' created successfully!"

    # Verify the domain was actually defined
    if $ROOT_ESC virsh dominfo "$DOMAIN_NAME" &>/dev/null; then
        fmtr::log "✓ Domain '$DOMAIN_NAME' is registered in libvirt."
        fmtr::info "Open virt-manager to see it, or run: sudo virsh list --all"
    else
        fmtr::error "virt-install exited successfully but domain '$DOMAIN_NAME' was NOT found in libvirt!"
        fmtr::error "Check the log: $LOG_FILE"
        return 1
    fi
}

# Enable debug mode with: DEBUG=1 ./modules/deploy.sh
fmtr::info "Starting VM deployment..."
[[ "${DEBUG:-0}" == "1" ]] && fmtr::warn "Debug mode is ON — extra logging enabled."

system_info || { fmtr::fatal "Failed to gather system information."; exit 1; }
configure_xml || { fmtr::fatal "VM deployment failed."; exit 1; }

fmtr::log "Deploy completed successfully."
