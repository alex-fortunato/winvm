#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${1:-win10pro.qcow2}"

# Prefer the invoking user's home when running via sudo so the ISO default still points to their Downloads.
USER_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
USER_HOME="${USER_HOME:-$HOME}"
ISO="${ISO:-$USER_HOME/Downloads/Win10_22H2_English_x64v1.iso}"
# Attach the installer ISO only when explicitly requested (set ATTACH_ISO=1).
ATTACH_ISO="${ATTACH_ISO:-0}"
USB_DEVICES=(${USB_DEVICES:-sdd sde})

if [[ ! -f "$DIR/$IMG" ]]; then
  echo "Image '$IMG' not found in $DIR" >&2
  exit 1
fi

MEM="${MEM:-8G}"
CPUS="${CPUS:-4}"
# Default to an emulated NIC with built-in Windows drivers; switch to virtio after installing its driver.
NIC_MODEL="${NIC_MODEL:-e1000}"

args=(
  -enable-kvm
  -m "$MEM"
  -smp "$CPUS"
  # Use AHCI/IDE so Windows sees the disk without extra drivers
  -drive "file=$DIR/$IMG,if=ide,index=0"
  # Prefer booting from the installed disk; menu stays available if you need to pick the CD later.
  -boot menu=on,order=c
  -display gtk
  -vga qxl
  -device virtio-tablet
  -device virtio-keyboard
  -nic "user,model=$NIC_MODEL"
)

if [[ -n "${UEFI_PATH:-}" ]]; then
  args+=(-bios "$UEFI_PATH")
fi

if [[ "$ATTACH_ISO" == "1" && -f "$ISO" ]]; then
  args+=(-drive "file=$ISO,media=cdrom,readonly=on")
fi

if [[ ${#USB_DEVICES[@]} -gt 0 ]]; then
  args+=(-device qemu-xhci)
  for dev in "${USB_DEVICES[@]}"; do
    if [[ -b "/dev/$dev" ]]; then
      args+=(-drive "if=none,file=/dev/$dev,format=raw,id=usb-$dev,cache=none")
      args+=(-device "usb-storage,drive=usb-$dev")
    else
      echo "Warning: /dev/$dev not found; skipping" >&2
    fi
  done
fi

exec qemu-system-x86_64 "${args[@]}"
