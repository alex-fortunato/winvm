# GPU Passthrough – Post-Reboot Checklist

After reboot, run these checks and capture outputs:

1. IOMMU active
   - `journalctl -k | rg -i iommu | head`

2. vfio modules
   - `lsmod | rg vfio`

3. GPU driver binding
   - `lspci -k -s 84:00.0`
   - `lspci -k -s 84:00.1`
   - Expect `vfio-pci` in use, not `nouveau`.

4. IOMMU groups
   - `find /sys/kernel/iommu_groups -maxdepth 2 -type l`
   - GPU and audio (`84:00.0/84:00.1`) should be isolated. If not, we may add `pcie_acs_override=downstream,multifunction` and rebuild.

5. VM hookup (once vfio confirmed)
   - Pass both devices into the Windows VM via libvirt/virt-manager/QEMU.
   - Keep host on the Matrox G200.

Bring the outputs to the next session so we can finalize.
