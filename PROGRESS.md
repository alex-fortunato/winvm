# Windows VM GPU passthrough notes

## What we changed
- Backed up grub config to `/etc/default/grub.bak-20260127061423`.
- Updated `/etc/default/grub` kernel params to bind the NVIDIA GPU + audio to vfio and keep nouveau off:
  - `intel_iommu=on iommu=pt vfio-pci.ids=10de:0a65,10de:0be3 modprobe.blacklist=nouveau rd.driver.blacklist=nouveau`
- Regenerated grub config: `grub-mkconfig -o /boot/grub/grub.cfg`.

## Why
- Host should keep using the onboard Matrox (mgag200), while the NVIDIA GeForce 210 (84:00.0/1) is dedicated to the Windows VM via VFIO.

## Next steps
- Reboot so the new kernel params take effect.
- After reboot verify:
  - `lspci -nnk -s 84:00.0` and `84:00.1` show `vfio-pci` in use.
  - `lsmod | grep nouveau` is empty.
  - Matrox (`08:03.0`) stays on `mgag200`.
- Launch VM with passthrough (example):
  - `GPU_MODEL=qxl EXTRA_ARGS="-display none -vga none -device vfio-pci,host=84:00.0,multifunction=on,x-vga=on -device vfio-pci,host=84:00.1" ./launch.sh`
- In Windows guest, install the NVIDIA driver for GeForce 210.
