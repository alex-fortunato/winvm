# WinVM passthrough state (Codex)

## Current state
- Host GPU: GeForce 210 (GT218) 84:00.0 + audio 84:00.1 bound to vfio-pci (verified via lspci/readlink).
- VM disk: win10pro.qcow2 intact (60 GB used). Default boot is SeaBIOS (UEFI default removed).
- Windows boot works via virtual display (qxl). NVIDIA legacy driver installed, but Code 43 persists when passing through the GPU.
- launch.sh changes:
  - Defaults: auto passthrough of 84:00.0/84:00.1 unless PASSTHROUGH_AUTO=0 or PASSTHROUGH_GPU/… set to none.
  - Hypervisor hiding by default: -cpu host,kvm=off,hv_vendor_id=123456789abc (overridable via CPU_VENDOR_ID/HIDE_HYPERVISOR).
  - Option to keep virtual display while passing through: PASSTHROUGH_KEEP_VDISPLAY=1 adds qxl + GTK window; otherwise -display none.
  - SeaBIOS by default; UEFI only if UEFI_PATH is set.

## How to launch
- With passthrough + virtual display (for management):
  ```
  sudo PASSTHROUGH_KEEP_VDISPLAY=1 XDG_RUNTIME_DIR=/run/user/1000 ./launch.sh
  ```
- Full passthrough (no window):
  ```
  sudo XDG_RUNTIME_DIR=/run/user/1000 ./launch.sh
  ```
- Force no passthrough (qxl window, use for troubleshooting):
  ```
  sudo PASSTHROUGH_AUTO=0 GPU_MODEL=qxl ATTACH_ISO=0 XDG_RUNTIME_DIR=/run/user/1000 ./launch.sh
  ```

## Next steps for Code 43
1) Boot full passthrough (no virtual display) with a fresh vendor ID:
   ```
   sudo CPU_VENDOR_ID=NoHyper123 PASSTHROUGH_KEEP_VDISPLAY=0 XDG_RUNTIME_DIR=/run/user/1000 ./launch.sh
   ```
   Reboot the guest once if needed.
2) If still Code 43, try another vendor id or remove virtual display entirely. Confirm both functions remain on vfio-pci: `lspci -nnk -s 84:00.0 -s 84:00.1`.
3) If persistent, consider adding a dumped VBIOS to PASSTHROUGH_GPU_ROM or using an older driver build; the card is legacy (GeForce 210).

## Notes
- bindtovfio-pci.sh handles binding 84:00.0/84:00.1 to vfio-pci.
- Audio/runtime vars are auto-set under sudo; use XDG_RUNTIME_DIR=/run/user/1000 to avoid Pulse errors.
- To stop a stuck VM: `sudo pkill -f "qemu-system-x86_64.*win10pro.qcow2"`.
