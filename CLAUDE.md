# winvm

## Current Status & Known Issues

**The machine was professionally configured by Vision DAW specifically for VEP hosting. A "modest" VEP template should run without issues, but performance is degraded in ways that are not explained by any observable resource bottleneck.**

### Active Problem: VEP GUI lag and slow instrument loading

Symptoms:
- VEP GUI becomes unresponsive / shows "Not Responding" as template size grows
- Instrument loading times increase as more instruments are loaded into the template
- Affects all plugin types (Kontakt, Spitfire BBCO, etc.) equally
- Occurs even when the audio engine is OFF and VEP is not connected to the DAW (so it is not a streaming/latency issue — it is a template-building/loading issue)
- Running VEP on macOS (native, not in a VM) works fine — confirms this is VM-specific

### What has been ruled out

| Area | Finding |
|---|---|
| CPU saturation | No cores near 100%; host CPU usage ~12%, guest ~32% during loading |
| RAM saturation | VM reports ~50% RAM usage during loading |
| Disk I/O | iostat shows 4–6% disk utilization, r_await 0.19ms, aqu-sz 0.05 — disk is idle |
| DPC latency | LatencyMon: clean pass |
| SMI stalls | WhySoSlow reported 481µs stalls; S3/S4 ACPI states have since been disabled to eliminate these |
| Windows HDD misidentification | Fixed: drives now correctly identified as SSD via virtio-scsi rotation_rate=1; throughput improved from 30 MB/s to 90–100 MB/s |
| QXL display overhead | Disabled in VEP_MODE |
| Virtual HDA audio overhead | Disabled in VEP_MODE |

### Optimizations already applied

- **Huge pages (2MB)**: VM RAM backed by hugetlbfs via `memory-backend-file`; reduces EPT TLB pressure
- **NUMA binding**: QEMU pinned to NUMA node 1 (CPUs 10–19, 30–39) via `numactl --preferred=1`
- **Per-vCPU thread pinning**: Each of the 20 KVM vCPU threads pinned to its physical SMT sibling pair via `taskset` after launch (QMP-based thread ID discovery); SCHED_FIFO attempted but may be blocked by systemd cgroup v2 RT limits
- **Extended Hyper-V enlightenments**: `hv_ipi`, `hv_tlbflush`, `hv_runtime`, `hv_frequencies` added on top of the original set
- **SMI mitigation**: `ICH9-LPC.disable_s3=1` and `disable_s4=1`
- **virtio-scsi with iothread and io_uring**: Dedicated iothread, `rotation_rate=1` for SSD identification, `aio=io_uring`

### Active experiment: 1GB huge pages (reboot required)

**Root cause identified**: Loading speed degrades progressively from ~20GB active guest RAM and flatlines at 32GB+. This matches EPT TLB saturation — with 2MB pages, 32GB of active memory requires ~16,384 EPT TLB entries; the hardware TLB is far smaller. With 1GB pages, only ~96 entries cover the whole VM.

**Changes already made:**
- `launch.sh`: MEM default raised 64G → 96G
- `/etc/sysctl.d/10-hugepages.conf`: nr_hugepages raised 33000 → 49500

**Pending (need to apply before next launch):**
```bash
# 1. Add 1GB hugepages kernel parameter
sudo sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 hugepagesz=1G hugepages=97"/' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
# 2. Reboot host
# 3. After reboot: mount hugetlbfs and persist
sudo mkdir -p /dev/hugepages1G
sudo mount -t hugetlbfs -o pagesize=1G nodev /dev/hugepages1G
echo 'nodev /dev/hugepages1G hugetlbfs pagesize=1G 0 0' | sudo tee -a /etc/fstab
# 4. Verify (should show 97)
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages
```

**Inside Windows after reboot:** Disable memory compression (elevated PowerShell):
```powershell
Disable-MMAgent -mc
```
Then reboot the VM once.

### Remaining hypotheses (not yet tried)

- **SCHED_FIFO blocked**: `chrt` silently fails due to cgroup RT limits; vCPU threads are pinned by CPU affinity but not elevated to RT priority. Fix: set `kernel.sched_rt_runtime_us=-1` (unlimited RT, safe on a dedicated machine) or use `systemd-run --scope -p RTBandwidth=90%` to escape cgroup limits before launching
- **Host CPU isolation**: Without `isolcpus=10-19,30-39` in kernel parameters, other host processes can still land on the pinned CPUs. Requires a reboot.
- **VEP internal threading**: VEP may serialize plugin loading through a main coordinator thread — the bottleneck may be internal to VEP's architecture, not the VM substrate. Unknown without VEP source access.
- **ACPI BOCHS strings**: QEMU's ACPI tables contain `BOCHS` OEM IDs. Some software is sensitive to this; patching requires a custom QEMU build (AUR: `qemu-patched`).

### Normal launch command

```bash
sudo VEP_MODE=1 HUGEPAGES=1g ./launch.sh
```

---

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
- **Samples**: `/dev/sda` raw passthrough (virtio-scsi, cache=none, aio=io_uring, rotation_rate=1)
- **Games/misc disk**: `/dev/sdc` (464.7GB) raw passthrough, same settings as samples disk
- **GPU**: Quadro K620 via vfio-pci passthrough
- **NIC**: virtio-net on `br0`, gets a real LAN IP via DHCP; MAC spoofed to Dell OUI (`F8:B4:6A:...`)

## Key Design Decisions

### CPU Pinning (NUMA + per-vCPU)
The QEMU process is launched under `numactl -C 10-19,30-39 --preferred=1`, restricting the process to NUMA node 1 CPUs and strongly preferring node 1 memory. `--preferred` rather than `--membind` is used because node 1 has ~63GB but the VM requests 64GB — strict binding would OOM-kill. The ~1GB overflow spills to node 0; the rest stays local.

After QEMU starts, the launch script pins each of the 20 KVM vCPU threads to a specific physical CPU and sets `SCHED_FIFO` priority 1 on each. The mapping aligns Windows' view of SMT topology with actual hardware:

| Windows sees | Physical CPUs |
|---|---|
| Core 0 (vCPU 0 + 1) | CPU 10 + CPU 30 |
| Core 1 (vCPU 2 + 3) | CPU 11 + CPU 31 |
| ... | ... |
| Core 9 (vCPU 18 + 19) | CPU 19 + CPU 39 |

Without per-vCPU pinning, vCPU threads float freely across all 20 allowed CPUs, which causes cache thrashing and scheduling jitter — especially problematic for VEP's main thread, which can end up sharing a physical core with a heavily loaded vCPU at the wrong time.

`SCHED_FIFO` ensures vCPU threads preempt any SCHED_OTHER host process on the same CPU. Combined with the pinning, VEP's main thread gets consistent, uncontested access to its physical core.

**Host CPU isolation (optional but ideal):** If other host processes are still landing on CPUs 10–19/30–39, they compete with the pinned vCPU threads. To fully isolate those CPUs, add to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`:
```
isolcpus=10-19,30-39 nohz_full=10-19,30-39 rcu_nocbs=10-19,30-39
```
Then `sudo grub-mkconfig -o /boot/grub/grub.cfg` and reboot. After isolation, the host scheduler will never assign any task to those CPUs unless explicitly asked.

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
- `hv_ipi` — paravirtualized IPIs; Windows signals vCPUs via a Hyper-V MSR rather than writing to the APIC, significantly cheaper when many threads are signaling each other (as VEP does internally)
- `hv_tlbflush` — batches TLB invalidation as a single hypercall instead of per-CPU APIC IPIs; reduces overhead of shared-memory coordination between plugin instances
- `hv_runtime` — exposes each vCPU's actual accumulated runtime to Windows scheduler so it can make better thread placement decisions
- `hv_frequencies` — exposes TSC and APIC clock frequencies via MSRs; gives Windows precise frequency data for accurate high-resolution timers

### Bridge Networking
The VM is connected to `br0` (bridged to `enp5s0f0`), so it gets a real LAN IP. This is mandatory for VEP: VEP Server uses broadcast/mDNS for discovery, which doesn't work through NAT. The Mac needs to see the VM as a real machine on the same subnet.

### Storage
- **C: drive**: qcow2 sparse image. Virtual size 250GB, actual host disk usage ~64GB. The gap is mainly because large Windows system files (pagefile.sys, hiberfil.sys) are mostly zeros which qcow2 doesn't store. Note: hibernation has been disabled (`powercfg /hibernate off`) to reclaim ~48GB on C:.
- **Samples disk**: `/dev/sda` passed via virtio-scsi with `cache=none,aio=io_uring,discard=unmap` and `rotation_rate=1`. The SCSI `rotation_rate=1` field tells Windows the device is non-rotating (SSD), enabling SSD I/O scheduling and higher queue depth — without this, Windows defaults to HDD behaviour and throttles concurrent I/O to ~30 MB/s. The dedicated iothread (`iothread-scsi`) keeps disk I/O off QEMU's main thread. Requires the **vioscsi** driver in Windows (virtio-win ISO: `vioscsi\w10\amd64\vioscsi.inf`). The games disk (`/dev/sdc`) shares the same virtio-scsi controller and settings.

### SMI Mitigation
QEMU's emulated ICH9 chipset generates System Management Interrupts (SMIs) for ACPI power management events including S3 (sleep) and S4 (hibernate) state transitions. SMIs are invisible to Windows — the CPU silently stalls in System Management Mode and resumes, which Windows sees as unexplained time gaps. These show up in tools like WhySoSlow as "SM BIOS interrupt or other stall" and can cause audio glitches and application unresponsiveness. Since the VM should never sleep or hibernate, both states are disabled via `-global ICH9-LPC.disable_s3=1` and `-global ICH9-LPC.disable_s4=1`, eliminating those SMI sources.

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
| `PIN_VCPUS` | `1` | Pin each vCPU thread to its physical SMT sibling pair and raise to `SCHED_FIFO` priority after launch. Requires root. Set to `0` to disable (reverts to unpinned floating). |

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
