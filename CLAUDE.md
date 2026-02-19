# winvm

## Purpose

This is a QEMU/KVM Windows 10 Pro VM that runs **Vienna Ensemble Pro (VEP) Server** as a dedicated sample playback slave. A Mac running Cubase connects to it over the LAN and offloads all sample library processing (Kontakt, etc.) onto this machine. The VM needs real-time audio performance and low latency.

## Host Hardware

- **Host OS**: Arch Linux on `/dev/sdb` (464.7GB)
- **CPU**: Multi-NUMA system. NUMA node 1 = CPUs 10–19 (physical cores) + 30–39 (hyperthreads) — 10 cores / 20 threads
- **GPU**: NVIDIA Quadro K620 at PCI `84:00.0` (GPU) and `84:00.1` (HDMI audio), lives on NUMA node 1
- **Samples disk**: `/dev/sda` (3.6TB), passed raw to the VM
- **USB drives**: `/dev/sdd` (14.9GB) and `/dev/sde` (119.2GB), passed through as USB storage — likely sample libraries
- **Bridge NIC**: `enp5s0f0` enslaved to `br0`; host LAN IP `192.168.1.166`

## VM Specs

- **RAM**: 64GB
- **CPUs**: 20 (sockets=1, cores=10, threads=2)
- **C: drive**: `win10pro.qcow2` — 250GB virtual, ~64GB actual on disk (qcow2 is sparse)
- **Samples**: `/dev/sda` raw passthrough (IDE, cache=none, aio=native)
- **GPU**: Quadro K620 via vfio-pci passthrough
- **NIC**: e1000 (emulated Intel GbE) on `br0`, gets a real LAN IP via DHCP

## Key Design Decisions

### CPU Pinning (NUMA)
The entire QEMU process is launched under `taskset -c 10-19,30-39`, pinning it exclusively to NUMA node 1. This ensures the VM's CPU threads, its memory allocations, and the K620 GPU all share the same NUMA node — eliminating cross-NUMA memory latency. Critical for real-time audio.

### GPU Passthrough (vfio-pci)
The K620 is passed directly to Windows via `vfio-pci`. A few important details:
- `multifunction=on` tells QEMU the GPU (`.0`) and its HDMI audio (`.1`) are one multi-function device
- `romfile=k620.rom` supplies a dumped copy of the card's VBIOS — required for stable passthrough on some cards
- `kvm=off` suppresses the KVM CPUID flag — NVIDIA drivers refuse to load if they detect they're in a VM
- `hv_vendor_id=whatever` randomizes the Hyper-V vendor string — another NVIDIA anti-detection workaround
- A secondary **QXL virtual GPU** is always added alongside the passthrough GPU, giving a management window on the Linux host via GTK

UEFI (OVMF) is required for GPU passthrough — the GPU needs UEFI GOP to initialize.

### Hyper-V Enlightenments
A set of `hv_*` CPU flags tells Windows it's in a Hyper-V environment (KVM supports this). Windows then uses paravirtualized paths for scheduling, timers, and interrupts, reducing latency and CPU overhead:
- `hv_relaxed` — relaxes timer deadline checks
- `hv_spinlocks=0x1fff` — spinlock retry hint
- `hv_vapic` — virtual APIC, lower interrupt overhead
- `hv_time` — Hyper-V reference time counter
- `hv_synic` / `hv_stimer` — synthetic interrupt controller and timer
- `hv_reset`, `hv_vpindex` — VM reset and virtual processor index support

### Bridge Networking
The VM is connected to `br0` (bridged to `enp5s0f0`), so it gets a real LAN IP. This is mandatory for VEP: VEP Server uses broadcast/mDNS for discovery, which doesn't work through NAT. The Mac needs to see the VM as a real machine on the same subnet.

### Storage
- **C: drive**: qcow2 sparse image. Virtual size 250GB, actual host disk usage ~64GB. The gap is mainly because large Windows system files (pagefile.sys, hiberfil.sys) are mostly zeros which qcow2 doesn't store. Note: hibernation has been disabled (`powercfg /hibernate off`) to reclaim ~48GB on C:.
- **Samples disk**: `/dev/sda` passed as a raw IDE device with `cache=none,aio=native` — bypasses host page cache for maximum sequential read throughput, important for streaming large sample libraries.

### SMBIOS Spoofing
The VM presents as a Dell OptiPlex 7010 with AMI BIOS. Helps with driver compatibility and software activation.

## Files

| File | Description |
|---|---|
| `launch.sh` | Main VM launch script |
| `launch-old.sh` | Original minimal script (pre-GPU passthrough, NAT, 8GB RAM) — kept for reference |
| `win10pro.qcow2` | Windows 10 Pro disk image (250GB virtual) |
| `k620.rom` | Dumped VBIOS ROM for the Quadro K620, required for vfio passthrough |
| `OVMF_VARS.4m.fd` | Per-VM UEFI NVRAM (mutable, auto-created from template on first run) |
| `vep-bridging-notes.md` | Notes on the bridge networking setup for VEP discovery |

## Environment Variables

All have defaults and can be overridden at launch time, e.g. `MEM=32G ./launch.sh`.

| Variable | Default | Description |
|---|---|---|
| `IMG` | `win10pro.qcow2` | qcow2 image filename |
| `MEM` | `64G` | VM RAM |
| `CPUS` | `20` | vCPU count |
| `SMP_TOPOLOGY` | `sockets=1,cores=10,threads=2` | CPU topology presented to Windows |
| `CPU_AFFINITY` | `10-19,30-39` | taskset CPU list (NUMA node 1) |
| `SAMPLES_DISK` | `/dev/sda` | Raw block device for sample libraries |
| `USB_DEVICES` | `sdd sde` | Block devices to pass through as USB storage |
| `USB_MODE` | `block` | `block` = USB mass storage emulation; `host` = direct USB host passthrough |
| `PASSTHROUGH_GPU` | `84:00.0` | PCI address of K620 GPU |
| `PASSTHROUGH_GPU_AUDIO` | `84:00.1` | PCI address of K620 HDMI audio |
| `GPU_MODEL` | `qxl` | Emulated GPU if passthrough is disabled (`virtio-gl`, `virtio`, `qxl`) |
| `FIRMWARE` | `uefi` | `uefi` (OVMF) or `bios` (SeaBIOS) |
| `NETWORK_MODE` | `auto` | `auto` tries bridge then tap; `bridge` or `tap` to force |
| `BRIDGE_NAME` | `br0` | Host bridge interface |
| `TAP_IFACE` | `tap0` | Tap interface for tap mode |
| `NIC_MODEL` | `e1000` | NIC model for Windows (`e1000` works out of box) |
| `PREFER_VIRTIO_NET` | `0` | Set to `1` once virtio drivers are installed in Windows |
| `AUDIO_BACKEND` | `pa` | PulseAudio (`pa`), ALSA, SDL, or `none` |
| `ATTACH_ISO` | `0` | Set to `1` to attach the Windows installer ISO |
| `ISO` | `~/Downloads/Win10_22H2_English_x64v1.iso` | Path to installer ISO |
| `QEMU_BIN` | `qemu-system-x86_64` | QEMU binary to use |
| `SHOW_NET_SETUP` | `0` | Set to `1` to print bridge/tap setup instructions and exit |

## VEP Workflow

1. Launch the VM with `./launch.sh` (requires root or appropriate permissions for vfio/bridge)
2. Windows boots; start VEP Server (64-bit) with "Advertise on local network" enabled
3. On the Mac, open Cubase and the VEP plugin — it discovers the server by LAN broadcast
4. Cubase routes instrument tracks to VEP Server; VEP streams audio back
5. All sample library CPU/RAM load runs on this Linux machine, not the Mac

## VEP Windows Checklist

- `ipconfig` shows a `192.168.1.x` LAN IP (not a 10.x NAT address)
- Network profile set to **Private**
- Network Discovery and File Sharing enabled on Private
- Windows Firewall allows `vvepsrv.exe` on Private (TCP + UDP), or use: `netsh advfirewall firewall add rule name="VEP Server" dir=in action=allow program="C:\...\vvepsrv.exe" enable=yes profile=private`

## Disk / Storage Notes

- The qcow2 image is on `/dev/sdb` (same disk as Linux). Keep the host disk from filling up — the qcow2 grows on write and cannot be auto-compacted without running `qemu-img convert`.
- To check actual qcow2 size on disk: `qemu-img info -U win10pro.qcow2`
- To resize: shut down VM, then `qemu-img resize win10pro.qcow2 <size>`, then extend the partition in Windows Disk Management.
- **Always make a backup before resizing or doing partition surgery.**
