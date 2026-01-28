#!/usr/bin/env bash
RUNTIME_DIR="/run/user/$(id -u)"
EXTRA_ARGS="-device vfio-pci,host=84:00.0,multifunction=on -device vfio-pci,host=84:00.1"

sudo XDG_RUNTIME_DIR="$RUNTIME_DIR" \
  GPU_MODEL=qxl \
  UEFI_PATH=/usr/share/edk2-ovmf/x64/OVMF.4m.fd \
  EXTRA_ARGS="$EXTRA_ARGS" \
  ./launch.sh
