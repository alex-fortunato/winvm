# winvm

## Purpose

This is a QEMU/KVM Windows 10 Pro VM with two purposes:
1. **Primary**: Runs **Vienna Ensemble Pro (VEP) Server** as a dedicated sample playback slave. A Mac running Cubase connects over the LAN and offloads all sample library processing (Kontakt, etc.). Needs real-time audio performance and low latency.
2. **Secondary**: Gaming (Steam). Launch with `GAMING_MODE=1` to hide the hypervisor from anti-cheat.

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
- **Samples**: `/dev/sda` raw passthrough (virtio-blk, cache=none, aio=native)
- **Games/misc disk**: `/dev/sdc` (464.7GB) raw passthrough, same settings as samples disk
- **GPU**: Quadro K620 via vfio-pci passthrough
- **NIC**: virtio-net on `br0`, gets a real LAN IP via DHCP; MAC spoofed to Dell OUI (`F8:B4:6A:...`)

## Key Design Decisions

### CPU Pinning (NUMA)
The entire QEMU process is launched under `numactl -C 10-19,30-39 --preferred=1`, pinning CPUs to NUMA node 1 and strongly preferring node 1 for memory allocation. `--preferred` rather than `--membind` is used because NUMA node 1 has ~63GB of physical RAM but the VM requests 64GB — strict binding would cause an OOM kill. With `--preferred`, the ~1GB overflow spills to node 0 while the rest stays local. Critical for real-time audio. (Previously used `taskset`, which only pinned CPUs but left memory allocation entirely unbound.)

### GPU Passthrough (vfio-pci)
The K620 is passed directly to Windows via `vfio-pci`. A few important details:
- `multifunction=on` tells QEMU the GPU (`.0`) and its HDMI audio (`.1`) are one multi-function device
- `romfile=k620.rom` supplies a dumped copy of the card's VBIOS — required for stable passthrough on some cards
- `kvm=off` suppresses the KVM CPUID flag — NVIDIA drivers refuse to load if they detect they're in a VM
- `hv_vendor_id=whatever` randomizes the Hyper-V vendor string — another NVIDIA anti-detection workaround
- A secondary **QXL virtual GPU** is added alongside the passthrough GPU by default, giving a management window on the Linux host via GTK — disable with `NO_QXL=1` (also the default in `VEP_MODE=1`)

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
- **Samples disk**: `/dev/sda` passed as a raw virtio-blk device with `cache=none,aio=native` — bypasses host page cache for maximum sequential read throughput, and virtio-blk allows high I/O queue depth so the SSD RAID can serve parallel reads efficiently. Important for streaming large sample libraries. Requires the `viostor` driver installed in Windows (from the virtio-win ISO, `viostor\w10\amd64\viostor.inf`).

### SMBIOS Spoofing & NIC MAC
The VM presents as a Dell OptiPlex 7010 with AMI BIOS across all SMBIOS types (0=BIOS, 1=system, 2=baseboard, 3=chassis). The NIC MAC address uses a real Dell OUI (`F8:B4:6A:3C:A1:7E`). Together these reduce VM fingerprinting from anti-cheat and driver compatibility checks.

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
| `CPU_AFFINITY` | `10-19,30-39` | numactl CPU list (NUMA node 1); memory strongly preferred on node 1 via `--preferred=1` (not `--membind` — see CPU Pinning note) |
| `SAMPLES_DISK` | `/dev/sda` | Raw block device for sample libraries |
| `Games464sdc` | `/dev/sdc` | Secondary 464GB disk (games/misc); virtio-blk passthrough, same settings as SAMPLES_DISK |
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
| `PREFER_VIRTIO_NET` | `1` | Uses virtio-net by default; set to `0` if the virtio NIC driver isn't installed in Windows |
| `AUDIO_BACKEND` | `pa` | PulseAudio (`pa`), ALSA, SDL, or `none`. When `none`, the HDA device is omitted entirely — no virtual audio device in Windows |
| `ATTACH_ISO` | `0` | Set to `1` to attach the Windows installer ISO |
| `ISO` | `~/Downloads/Win10_22H2_English_x64v1.iso` | Path to installer ISO |
| `QEMU_BIN` | `qemu-system-x86_64` | QEMU binary to use |
| `SHOW_NET_SETUP` | `0` | Set to `1` to print bridge/tap setup instructions and exit |
| `GAMING_MODE` | `0` | Set to `1` to strip Hyper-V enlightenments and clear the hypervisor CPUID bit — hides the VM from anti-cheat (EAC). Slight latency tradeoff; don't use for VEP sessions. |
| `NO_QXL` | `0` | Set to `1` to disable the QXL virtual display and GTK management window. The passthrough GPU display still works. |
| `VEP_MODE` | `0` | Set to `1` for sample-server mode: disables QXL and omits the HDA audio device. CPU topology is unchanged (still 20 vCPUs with SMT). All individual variables can still be overridden. Example: `VEP_MODE=1 NO_QXL=0 ./launch.sh` re-enables QXL. |
| `HUGEPAGES` | `0` | Set to `2m` or `1g` to back VM RAM with huge pages, reducing EPT TLB pressure at high memory usage. Requires host-side setup — see Huge Pages section below. |

## VEP Workflow

1. Launch the VM with `sudo VEP_MODE=1 ./launch.sh` for optimised sample-server defaults (no QXL window, no HDA device, full 20 vCPUs). Add `HUGEPAGES=2m` if huge pages are configured on the host. Or use plain `./launch.sh` if you want the management window / audio device.
2. Windows boots; start VEP Server (64-bit) with "Advertise on local network" enabled
3. On the Mac, open Cubase and the VEP plugin — it discovers the server by LAN broadcast
4. Cubase routes instrument tracks to VEP Server; VEP streams audio back
5. All sample library CPU/RAM load runs on this Linux machine, not the Mac

## VEP Windows Checklist

- `ipconfig` shows a `192.168.1.x` LAN IP (not a 10.x NAT address)
- Network profile set to **Private**
- Network Discovery and File Sharing enabled on Private
- Windows Firewall allows `vvepsrv.exe` on Private (TCP + UDP), or use: `netsh advfirewall firewall add rule name="VEP Server" dir=in action=allow program="C:\...\vvepsrv.exe" enable=yes profile=private`

## Mouse Sharing (Barrier)

[Barrier](https://github.com/debauchee/barrier) is installed on both the Mac and the Windows VM to share one mouse and keyboard across both monitors seamlessly.

- **Mac** = Barrier Server (primary machine with mouse/keyboard)
- **Windows VM** = Barrier Client
- The VM's dedicated K620 monitor appears as a second screen in Barrier's layout
- SSL is disabled in Barrier Preferences on both sides (trusted LAN, avoids certificate mismatch issues)
- Windows Firewall has an inbound rule allowing TCP port 24800 on the Private profile

Note: [Input Leap](https://github.com/input-leap/input-leap) is the actively maintained successor to Barrier. Consider migrating if Barrier causes issues.

## Huge Pages

Backing VM RAM with huge pages reduces EPT (Extended Page Table) TLB pressure. With 4KB pages and 64GB of RAM, the hypervisor must manage millions of page table entries; frequent TLB misses add latency to every guest memory access. Huge pages collapse this dramatically.

The launch script validates that enough free pages exist before starting QEMU and exits with a clear error if they don't — no silent fallback.

**2MB pages — recommended, allocatable at runtime:**

Option A — persist across reboots via sysctl (recommended):
```bash
# Create a sysctl drop-in (applied automatically at every boot):
echo 'vm.nr_hugepages = 33000' | sudo tee /etc/sysctl.d/10-hugepages.conf
# Apply immediately without rebooting:
sudo sysctl -p /etc/sysctl.d/10-hugepages.conf
# Verify (free_hugepages should be ≥ 32768):
cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages
```

Option B — one-time allocation (resets on reboot):
```bash
sudo bash -c 'echo 33000 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages  # should be ≥ 32768
```

Then launch with `HUGEPAGES=2m ./launch.sh`. hugetlbfs is mounted at `/dev/hugepages` by systemd automatically on Arch.

**1GB pages** (better EPT reduction, but requires a kernel boot parameter — try 2MB first):
```bash
# Add to GRUB_CMDLINE_LINUX in /etc/default/grub:
#   hugepagesz=1G hugepages=65
# Then:
sudo grub-mkconfig -o /boot/grub/grub.cfg && reboot
# After reboot, mount the 1G hugetlbfs and make it persistent:
sudo mkdir -p /dev/hugepages1G
sudo mount -t hugetlbfs -o pagesize=1G nodev /dev/hugepages1G
echo 'nodev /dev/hugepages1G hugetlbfs pagesize=1G 0 0' | sudo tee -a /etc/fstab
```
Then launch with `HUGEPAGES=1g ./launch.sh`.

**Notes:**
- The script uses the modern QEMU `memory-backend-file` object, which correctly maps the pre-allocated pages to the VM rather than allocating new memory on top of them.
- The full 64GB is locked immediately at VM start — the host needs enough free huge pages or the launch aborts before QEMU even starts.
- To release pages (Option B only): `sudo bash -c 'echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'`

## Host Tuning (Real-time Audio)

- **CPU governor**: NUMA node 1 cores (10–19, 30–39) should be set to `performance` to prevent frequency scaling latency spikes. This resets on reboot — set it before launching the VM:
  ```bash
  sudo bash -c 'for cpu in $(seq 10 19) $(seq 30 39); do echo performance > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor; done'
  ```
- **Windows power plan**: Set to **High Performance** inside the VM (Control Panel → Power Options).

## Gaming

Launch with `sudo GAMING_MODE=1 ./launch.sh`. This strips the `hv_*` Hyper-V enlightenment flags and clears the CPUID hypervisor present bit (`-hypervisor`), making Windows report no hypervisor in System Information — which is what EAC checks.

**GPU limitation**: The Quadro K620 only supports DirectX 12 at feature level 11_0 and is below the minimum spec for many modern games (e.g. Marvel Rivals requires GTX 1060 / DX12 FL 12_0+). A Pascal-generation GPU or newer is needed for those titles.

**What GAMING_MODE does NOT fix**: ACPI tables still contain `BOCHS` OEM strings, which aggressive anti-cheat may detect. If a game still blocks after GAMING_MODE, ACPI table spoofing is the next step (requires a patched QEMU build — search AUR for `qemu-patched` or similar).

## Disk / Storage Notes

- The qcow2 image is on `/dev/sdb` (same disk as Linux). Keep the host disk from filling up — the qcow2 grows on write and cannot be auto-compacted without running `qemu-img convert`.
- To check actual qcow2 size on disk: `qemu-img info -U win10pro.qcow2`
- To resize: shut down VM, then `qemu-img resize win10pro.qcow2 <size>`, then extend the partition in Windows Disk Management.
- **Always make a backup before resizing or doing partition surgery.**
- Backup files `win10pro.qcow2.bak` and `OVMF_VARS.4m.fd.bak` exist from before the virtio migration. Safe to delete once the VM is confirmed stable.
