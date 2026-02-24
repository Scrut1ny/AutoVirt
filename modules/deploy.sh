#!/usr/bin/env bash

source ./utils.sh || { echo "Failed to load utilities module!"; exit 1; }

system_info() {
    # Domain Name
    DOMAIN_NAME="AutoVirt"

    # CPU Topology
    HOST_LOGICAL_CPUS=$(nproc --all 2>/dev/null || nproc 2>/dev/null)
    HOST_CORES_PER_SOCKET=$(LC_ALL=C lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p')
    HOST_THREADS_PER_CORE=$(LC_ALL=C lscpu | sed -n 's/^Thread(s) per core:[[:space:]]*//p')

    # MAC Address (Uses host's OUI)
    UPLINK_IFACE=$(nmcli -t device show | awk -F: '
    /^GENERAL.DEVICE/ {dev=$2}
    /^GENERAL.TYPE/   {type=$2}
    /^IP4.GATEWAY/ && $2!="" && type!="wireguard" {print dev; exit}
    ')
    OUI=$(cat /sys/class/net/"$UPLINK_IFACE"/address | awk -F: '{print $1 ":" $2 ":" $3}')
    RANDOM_MAC="$OUI:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"

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
    DOWNLOADS_DIR="/var/lib/libvirt/images/"
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
}

configure_xml() {
    if $ROOT_ESC virsh dominfo "$DOMAIN_NAME" >/dev/null 2>&1; then
        fmtr::fatal "Domain '$DOMAIN_NAME' already exists. Please delete it before running this script."
        return 1
    fi

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

        --qemu-commandline="-smbios file=/opt/AutoVirt/firmware/smbios.bin"





        ################################################################################
        #
        # Miscellaneous Options:
        #

        --noautoconsole
        --wait
    )
    # https://man.archlinux.org/man/virt-install.1
    # sudo virt-install --features help

    # TODO: Figure out weird boot hang freeze

    $ROOT_ESC virt-install "${args[@]}" &>> "$LOG_FILE"

    # $ROOT_ESC virt-install "${args[@]}" --print-xml > /tmp/AutoVirt.xml &>> "$LOG_FILE"

    # virt-manager --connect qemu:///system --show-domain-console "$DOMAIN_NAME" &>> "$LOG_FILE"
}

system_info
configure_xml
