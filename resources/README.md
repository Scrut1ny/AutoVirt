## 🛠️ Troubleshooting

<details>
<summary>Expand for details...</summary>

- Fix Ryzen 7000/9000 iGPUs "No Signal/Black Screen/flickering" when attempting to display the DM
Add the arg below to your kernel options config:
```
amdgpu.sg_display=0
```
- https://www.kernel.org/doc/html/latest/gpu/amdgpu/module-parameters.html
  - sg_display (int)
    - Disable S/G (scatter/gather) display (i.e., display from system memory). This option is only relevant on APUs. Set this option to 0 to disable S/G display if you experience flickering or other issues under memory pressure and report the issue.

---

- Hypervisor + VPN
  - Custom DNS in guest while host VPN uses custom DNS may break internet.
  - Turn on local network sharing in the host VPN so the guest has internet access.

</details>





---





## 📚 References

<details>
<summary>Expand for details...</summary>

- **Virtualization**
  - [QEMU’s documentation](https://www.qemu.org/docs/master/)
    - [Invocation](https://www.qemu.org/docs/master/system/invocation.html) | [Man Page (Args)](https://www.qemu.org/docs/master/system/qemu-manpage.html)
    - [Hyper-V Enlightenments](https://www.qemu.org/docs/master/system/i386/hyperv.html)
  - [KVM for x86 systems (Linux Kernel)](https://www.kernel.org/doc/html/next/virt/kvm/x86/index.html)
  - [libvirt - Domain XML format](https://libvirt.org/formatdomain.html)
- **Specifications**
  - [www.dmtf.org](https://www.dmtf.org/standards/smbios)
    - [SMBIOS](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)
  - [uefi.org](https://uefi.org/specifications)
    - [ACPI](https://uefi.org/sites/default/files/resources/ACPI_Spec_6.6.pdf)
      - [ACPI ID Registry](https://uefi.org/ACPI_ID_List)
    - [UEFI](https://uefi.org/sites/default/files/resources/UEFI_Spec_Final_2.11.pdf)
  - [pcisig.com](https://pcisig.com/specifications)
    - [PCI Code and ID Assignment Specification Revision 1.19](https://members.pcisig.com/document/dl/22472)
    - [PCILookup](https://www.pcilookup.com/)
  - [www.usb.org](https://www.usb.org/)
    - [Device Class Definition for HID](https://www.usb.org/sites/default/files/hid1_11.pdf)
    - [HID Usage Tables](https://www.usb.org/sites/default/files/hut1_7.pdf)
    - [Defined Class Codes](https://www.usb.org/defined-class-codes)
- **Blogs**
  - [https://evasions.checkpoint.com/](https://evasions.checkpoint.com/)
  - [https://r0ttenbeef.github.io/](https://r0ttenbeef.github.io/Deploy-Hidden-Virtual-Machine-For-VMProtections-Evasion-And-Dynamic-Analysis/)
  - [https://secret.club/](https://secret.club/)
    - [how-anti-cheats-detect-system-emulation.html](https://secret.club/2020/04/13/how-anti-cheats-detect-system-emulation.html)
    - [battleye-hypervisor-detection.html](https://secret.club/2020/01/12/battleye-hypervisor-detection.html)
  - [https://revers.engineering/](https://revers.engineering/day-5-vmexits-interrupts-cpuid-emulation/)
- **Git Repositories**
  - [pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc)
  - [Nika-Read-Only](https://github.com/Ape-xCV/Nika-Read-Only)
  - [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection)

</details>





---





## 💾 Software

<details>
<summary>Virtual Audio & Video (AV)</summary>

## Video
- Display
  - [LookingGlass](https://github.com/gnif/LookingGlass)
    - [Virtual-Display-Driver](https://github.com/itsmikethetech/Virtual-Display-Driver)
  - [memflow-mirror](https://github.com/ko1N/memflow-mirror)
  - [Sunshine](https://github.com/LizardByte/Sunshine)
  - [Moonlight](https://github.com/moonlight-stream/moonlight-qt)
- Streaming (WHIP/WHEP)
  - [meshcast.io](https://meshcast.io/)
  - [VDO.Ninja](https://vdo.ninja/)
- Webcam Manipulation
  - [Deep-Live-Cam](https://github.com/hacksider/Deep-Live-Cam)

## Audio
- [VB-AUDIO](https://vb-audio.com/Cable/index.htm)

</details>





---





## 🔩 Hardware

<details>
<summary>HDCP</summary>

#### HDCP (High-bandwidth Digital Content Protection) Stuff
- [Wikipedia - HDCP](https://en.wikipedia.org/wiki/High-bandwidth_Digital_Content_Protection)
- [NVIDIA - To verify if your system is HDCP-capable](https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/Display/To_verify_if_your_system_is_HDCP-capable.htm)

## HDCP Hardware/Software Diagram:
![setup](https://github.com/Scrut1ny/Hypervisor-Phantom/assets/53458032/589b0f88-f14b-44d8-bf1c-225df4d01e54)

## Kits

#### Expensive Kit (Recommended):
- 1x2 HDMI Splitter <> [U9/ViewHD - VHD-1X2MN3D](https://www.amazon.com/dp/B086JKRSW1) - `~$18.00`
- EDID Emulator <> [4K-EWB - HDMI 2.1 4K EDID Emulator](https://www.amazon.com/dp/B0DB7YDFD6) - `~$25.00`
- USB HDMI Capture Card <> [Elgato HD60 X](https://www.amazon.com/dp/B09V1KJ3J4) - `~$160.00`

#### Cheap Kit (Not recommended):
- 1x2 HDMI Splitter <> [OREI](https://www.amazon.com/dp/B005HXFARS) - `~$13.00`
- EDID Emulator <> [EVanlak](https://www.amazon.com/dp/B07YMTKJCR) - `~$7.00`
- USB HDMI Capture Card <> [AXHDCAP](https://www.amazon.com/dp/B0C2MDTY8P) - `~$9.00`

## Equipment List
- External USB Capture Card(s)
    - Elgato
        - [HD60 X | 10GBE9901](https://www.amazon.com/dp/B09V1KJ3J4) - `~$140.00`
        - [4K X | 20GBH9901](https://www.amazon.com/dp/B0CPFWXMBL) - `~$200.00`
        - [Game Capture Neo | 20GBI9901](https://www.amazon.com/dp/B0CVYKQNFH) - `~$110.00`
        - [Cam Link](https://www.amazon.com/dp/B07K3FN5MR) - `~$90.00`
    - [AXHDCAP 4K HDMI Video Capture Card](https://www.amazon.com/dp/B0C2MDTY8P) - `~$9.98`
- 1x2 HDMI Splitter(s)
    - [U9 / ViewHD](https://u9ltd.myshopify.com/collections/splitter)
        - [VHD-1X2MN3D](https://www.amazon.com/dp/B004F9LVXC) - `~$22.00`
        - [VHD-1X2MN3D](https://www.amazon.com/dp/B086JKRSW1) - `~$18.00`
    - HBAVLINK
        - [HB-SP102B](https://www.amazon.com/dp/B08T62MKH1)
        - [HB-SP102C](https://www.amazon.com/dp/B08T64JWWT)
    - CORSAHD
        - [CO-SP12H2](https://www.amazon.com/dp/B0CLL5GQXT)
        - [?????????](https://www.amazon.com/dp/B0CXHQNSWM)
    - EZCOO
        - [EZ-SP12H2](https://www.amazon.com/dp/B07VP37KMB)
        - [EZ-EX11HAS-PRO](https://www.amazon.com/dp/B07TZRXKYG)
- EDID Emulator(s)
    - HDMI
        - Brand: THWT
            - [4K-EW2 - HDMI 2.1 4K EDID Emulator PRO](https://www.amazon.com/dp/B0DB65Y6VL) - `~$90.00`
            - [4K-EWB - HDMI 2.1 4K EDID Emulator](https://www.amazon.com/dp/B0DB7YDFD6) - `~$25.00`
            - [HD-EW2 - HDMI 2.0 EDID Emulator 4K PRO](https://www.amazon.com/dp/B0C32ZWBR6) - `~$90.00`
            - [HD-EWB - HDMI 2.0 4K EDID Emulator](https://www.amazon.com/dp/B0CRRWQ7XS) - `~$20.00`
    - DP
        - Brand: THWT
            - [DPH-EW2 - Displayport 1.2 EDID Emulator 4K PRO](https://www.amazon.com/dp/B0C32NJ2NF) - `~$90.00`
    - DP to HDMI
        - Brand: THWT
            - [DPH-EWB - Displayport 1.2 to HDMI 2.0 EDID Emulator](https://www.amazon.com/dp/B0C3H763FG) - `~$20.00`

</details>







<details>
<summary>I²C EEPROM</summary>

- EEPROM (**E**lectrically **E**rasable **P**rogrammable **R**ead-**O**nly **M**emory)

## EDID (**E**xtended **D**isplay **I**dentification **D**ata)
- [EDID structure, version 1.4](https://en.wikipedia.org/wiki/Extended_Display_Identification_Data#Structure,_version_1.4)
  - Bytes 12–15: Serial number. 32 bits, little-endian.

- [EDID Analysis & Generation Tool](https://edidcraft.com/)

- Monitor EDID Modifiers
  - EEPROM EDID (Hardware)
    - [Monitor Tests](https://www.monitortests.com/)
      - [EDID/DisplayID Writer](https://www.monitortests.com/forum/Thread-EDID-DisplayID-Writer)
  - Windows INF override registry EDID (Software)
    - [Monitor Tests](https://www.monitortests.com/)
      - [Custom Resolution Utility (CRU)](https://www.monitortests.com/forum/Thread-Custom-Resolution-Utility-CRU)
    - [Monitor Asset Manager](https://www.entechtaiwan.com/util/moninfo.shtm)

</details>
